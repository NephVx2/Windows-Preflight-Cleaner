#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Nettoyage-Windows11 v5.2 - Suite de maintenance et nettoyage Windows 11

.DESCRIPTION
    Nettoie les caches systeme et applicatifs, journaux obsoletes, fichiers temporaires
    multi-utilisateurs et composants WinSxS. Genere un rapport HTML (theme sombre, type
    tableau de bord : tuiles de synthese, barre d'usage disque, Top Gains, infos systeme,
    tendance sur les derniers runs, duree par cible), un export CSV d'historique, un export
    JSON complet et une baseline JSON permettant le calcul d'un delta par rapport au run
    precedent. Purge automatiquement les anciens rapports au-dela de -RetainReportsDays.

.PARAMETER Silent
    Supprime les invites interactives (confirmation ResetBase, pause ENTREE) et n'ouvre pas
    automatiquement le rapport HTML dans le navigateur (utile pour une tache planifiee).

.PARAMETER DryRun
    Mode simulation : calcule les gains potentiels sans rien supprimer ni executer DISM.

.PARAMETER SelfTest
    Verifie les prerequis (droits admin, robocopy, DISM, ecriture du dossier rapports,
    services) puis quitte sans effectuer de nettoyage.

.PARAMETER CreateRestorePoint
    Cree un point de restauration systeme avant le nettoyage DISM (soumis au throttle
    Windows de 1 point/24h pour le type MODIFY_SETTINGS).

.PARAMETER ResetBase
    Ajoute /ResetBase au nettoyage DISM : supprime DEFINITIVEMENT les anciennes versions
    de composants WinSxS (plus de rollback de mises a jour possible). Demande confirmation
    interactive sauf si -Silent est utilise.

.PARAMETER SkipTargets
    Liste de noms de cibles a ignorer (voir les noms affiches dans la console, ex: "Cache npm").

.PARAMETER OnlyTargets
    Liste de noms de cibles a traiter exclusivement (toutes les autres sont ignorees).

.PARAMETER RetainReportsDays
    Nombre de jours de retention des rapports HTML/JSON/Transcript avant purge automatique
    en fin de run (defaut: 60). Le CSV d'historique et la baseline JSON ne sont jamais purges.
    Utiliser -RetainReportsDays 0 pour desactiver la purge.

.EXAMPLE
    .\Nettoyage-Windows11-v5_1-Pro.ps1 -DryRun
    Simulation complete sans suppression, pour previsualiser les gains.

.EXAMPLE
    .\Nettoyage-Windows11-v5_1-Pro.ps1 -Silent -SkipTargets "Prefetch","Steam AppCache"
    Run silencieux (tache planifiee) en ignorant deux cibles sensibles.

.EXAMPLE
    .\Nettoyage-Windows11-v5_1-Pro.ps1 -CreateRestorePoint -ResetBase
    Run isole avec point de restauration et purge definitive de WinSxS (confirmation requise).

.EXAMPLE
    .\Nettoyage-Windows11-v5_1-Pro.ps1 -RetainReportsDays 30
    Run standard, ne conserve que 30 jours de rapports au lieu de 60.

.NOTES
    Auteur  : Erwan
    Version : 5.2
    A signer via Sign-MyScripts.ps1 avant mise en production.

.NOTES
    Codes de sortie (utile pour supervision via Tache planifiee) :
      0 = run complet, rien a signaler
      1 = run complet mais avec cibles verrouillees/protegees, ou SelfTest en echec
      2 = erreur fatale non geree
#>

[CmdletBinding()]
param(
    [switch]$Silent,
    [switch]$DryRun,
    [switch]$SelfTest,
    [switch]$CreateRestorePoint,
    [switch]$ResetBase,
    [string[]]$SkipTargets,
    [string[]]$OnlyTargets,
    [int]$RetainReportsDays = 60
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Filet de securite global : toute erreur terminante non interceptee localement
# (donc non prevue par les try/catch existants) remonte ici plutot que de
# planter silencieusement avec un code de sortie ambigu. Permet a une Tache
# planifiee / supervision multi-machines de distinguer un echec reel (code 2)
# d'un run normal (code 0) ou d'un run avec cibles verrouillees (code 1).
trap {
    Write-Host ""
    Write-Host "====================================================" -ForegroundColor Red
    Write-Host "  ERREUR FATALE : $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "====================================================" -ForegroundColor Red
    if (-not $Silent) { Read-Host "  Appuyez sur ENTREE pour fermer" | Out-Null }
    exit 2
}

# ============================================================================
#  AUTO-ELEVATION
# ============================================================================
$CurrentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $CurrentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $RelayArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath)
    if ($Silent)             { $RelayArgs += '-Silent' }
    if ($DryRun)              { $RelayArgs += '-DryRun' }
    if ($SelfTest)            { $RelayArgs += '-SelfTest' }
    if ($CreateRestorePoint)  { $RelayArgs += '-CreateRestorePoint' }
    if ($ResetBase)           { $RelayArgs += '-ResetBase' }
    if ($SkipTargets)         { $RelayArgs += '-SkipTargets'; $RelayArgs += $SkipTargets }
    if ($OnlyTargets)         { $RelayArgs += '-OnlyTargets'; $RelayArgs += $OnlyTargets }
    Start-Process -FilePath 'pwsh' -Verb RunAs -ArgumentList $RelayArgs
    exit
}

# ============================================================================
#  FONCTIONS UTILITAIRES
# ============================================================================
function He {
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return "" }
    return [System.Net.WebUtility]::HtmlEncode($Text)
}

function Format-Size {
    param([int64]$Bytes)
    if ($Bytes -ge 1GB) { return "{0:N2} Go" -f ($Bytes / 1GB) }
    elseif ($Bytes -ge 1MB) { return "{0:N2} Mo" -f ($Bytes / 1MB) }
    elseif ($Bytes -ge 1KB) { return "{0:N2} Ko" -f ($Bytes / 1KB) }
    else { return "$Bytes octets" }
}

# Formate une valeur en Go avec la virgule francaise, pour cohabiter visuellement
# avec Format-Size dans la console et le rapport HTML. Ne pas utiliser pour les
# valeurs ecrites en JSON/CSV : celles-ci doivent rester des nombres bruts.
function Format-Go {
    param([double]$Value)
    return "{0:N2}" -f $Value
}

# Pourcentage en virgule FR, pour texte affiche uniquement (jamais dans un attribut CSS/SVG).
function Format-Pct {
    param([double]$Value)
    return "{0:N1}" -f $Value
}

# Formatage en culture invariante (point decimal), obligatoire pour toute valeur
# inseree dans un attribut CSS (ex: width:12.3%) ou SVG : un format FR avec virgule
# y casserait le rendu (meme classe de bug que la sparkline v5.0).
function Format-NumInvariant {
    param([double]$Value, [string]$NumFormat = "F1")
    return $Value.ToString($NumFormat, [System.Globalization.CultureInfo]::InvariantCulture)
}

function Write-Step {
    param([string]$Message, [string]$Status = "INFO")
    $color = switch ($Status) {
        "OK"    { "Green" }
        "WARN"  { "Yellow" }
        "ERROR" { "Red" }
        default { "Cyan" }
    }
    Write-Host $Message -ForegroundColor $color
}

# En-tete de categorie affiche dans la console pour aerer visuellement les 46
# cibles de nettoyage (regroupement purement cosmetique, sans impact sur les
# rapports HTML/CSV/JSON qui restent bases sur $Results).
function Write-Category {
    param([string]$Title)
    Write-Host ""
    Write-Host "  $Title" -ForegroundColor DarkCyan
}

# Compose une ligne de cible en une seule impression alignee : prefixe [n/46]
# en gris, icone de statut coloree, nom de la cible aligne sur colonne fixe,
# puis detail attenue (ou rien si non pertinent). Remplace l'ancien format a
# deux lignes (mesure Avant/Apres/Gain/Duree + ligne de statut) qui produisait
# un decalage visuel entre la ligne de chiffres et celle qui la qualifie.
function Write-TargetLine {
    param(
        [string]$Prefix,
        [string]$Name,
        [string]$Icon,
        [string]$IconColor,
        [string]$Detail = "",
        [string]$DetailColor = "DarkGray"
    )
    $padWidth = 34
    Write-Host $Prefix -NoNewline -ForegroundColor DarkGray
    Write-Host "$Icon " -NoNewline -ForegroundColor $IconColor
    if ($Name.Length -ge $padWidth) {
        # Nom trop long pour la colonne (ex: profils LibreWolf avec suffixe) :
        # le detail passe sur la ligne suivante, indente pour rester lisible
        # plutot que de casser l'alignement des autres lignes.
        Write-Host $Name -ForegroundColor White
        if ($Detail) {
            $indent = " " * ($Prefix.Length + 2)
            Write-Host "$indent$Detail" -ForegroundColor $DetailColor
        }
    } else {
        Write-Host $Name.PadRight($padWidth) -NoNewline
        if ($Detail) { Write-Host $Detail -ForegroundColor $DetailColor } else { Write-Host "" }
    }
}

# Variante de Write-TargetLine pour les actions hors boucle des 46 cibles (DNS,
# corbeille, DISM, point de restauration) : meme rendu icone+colonne, mais sans
# compteur [n/46]. Le prefixe de 8 espaces reproduit la largeur de "[ 1/46] "
# pour garder les colonnes alignees entre les deux styles de ligne.
function Write-ActionLine {
    param(
        [string]$Name,
        [string]$Icon,
        [string]$IconColor,
        [string]$Detail = "",
        [string]$DetailColor = "DarkGray"
    )
    Write-TargetLine -Prefix "        " -Name $Name -Icon $Icon -IconColor $IconColor -Detail $Detail -DetailColor $DetailColor
}

function Get-FolderSizeBytes {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return 0L }
    try {
        $sum = (Get-ChildItem -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue |
            Where-Object { -not $_.PSIsContainer } |
            Measure-Object -Property Length -Sum).Sum
        if ($null -eq $sum) { return 0L }
        return [int64]$sum
    } catch {
        return 0L
    }
}

function Add-Result {
    param([string]$Name, [int64]$Before, [int64]$After, [int]$Count, [Nullable[int64]]$GainOverride = $null, [int64]$ElapsedMs = 0, [int]$Remaining = 0)
    [int64]$gain = if ($null -ne $GainOverride) { $GainOverride } else { [math]::Max(0L, $Before - $After) }
    $null = $Results.Add([pscustomobject]@{
        Cible             = $Name
        AvantOctets       = $Before
        ApresOctets       = $After
        GainOctets        = $gain
        AvantFormate      = Format-Size $Before
        ApresFormate      = Format-Size $After
        GainFormate       = Format-Size $gain
        ElementsSupprimes = $Count
        ElementsRestants  = $Remaining
        DureeMs           = $ElapsedMs
    })
}

# Suppression rapide d'un dossier via robocopy /MIR (vide une copie miroir d'un
# dossier vide vers la cible). Beaucoup plus rapide que Remove-Item -Recurse sur
# les dossiers contenant un grand nombre de petits fichiers (caches navigateur, npm...).
# Le comptage avant/apres reste independant de la langue de la sortie robocopy
# (jamais de parsing texte localise, contrairement a la sortie console de robocopy).
# Garde-fou de securite : refuse toute cible de nettoyage situee a moins de
# 2 niveaux sous la racine d'un lecteur (C:\, C:\Windows, C:\Users...).
# Toutes les cibles legitimes du script (Prefetch, SoftwareDistribution\Download,
# caches navigateurs...) sont a 2 niveaux ou plus. Ce garde-fou protege contre une
# future erreur de saisie de chemin qui ferait passer un dossier systeme entier
# dans Remove-DirectoryFast (robocopy /MIR est destructif par nature).
function Test-SafeCleanupPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    $normalized = $Path.TrimEnd('\')
    $withoutDrive = $normalized -replace '^[A-Za-z]:\\?', ''
    $segments = @($withoutDrive -split '\\' | Where-Object { $_ -ne '' })
    return ($segments.Count -ge 2)
}

function Remove-DirectoryFast {
    param([string]$Path)
    [int]$before = 0
    try {
        $before = (Get-ChildItem -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue | Measure-Object).Count
    } catch {}

    try {
        $emptyDir = Join-Path $env:TEMP ("RoboEmpty_" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $emptyDir -Force -ErrorAction Stop | Out-Null
        & robocopy.exe $emptyDir $Path /MIR /R:0 /W:0 /NP /NFL /NDL /NJH /NJS *> $null
        Remove-Item -LiteralPath $emptyDir -Recurse -Force -ErrorAction SilentlyContinue
    } catch {}

    [int]$after = 0
    try {
        $after = (Get-ChildItem -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue | Measure-Object).Count
    } catch {}

    # Remaining > 0 alors que before > 0 signale un verrouillage (fichiers en cours
    # d'utilisation) plutot qu'un dossier deja vide : le distinguo est fait par
    # l'appelant (Clear-Target), pas ici, pour rester une fonction de bas niveau.
    return [pscustomobject]@{
        Removed   = [math]::Max(0, $before - $after)
        Remaining = $after
    }
}

# Nettoie une cible (dossier OU fichier unique), gere -DryRun, -SkipTargets, -OnlyTargets.
function Clear-Target {
    param([string]$Name, [string]$Path)

    $script:StepCounter++
    $prefix = "[{0,2}/{1}] " -f $script:StepCounter, $script:TotalSteps

    if (-not (Test-SafeCleanupPath -Path $Path)) {
        Write-TargetLine -Prefix $prefix -Name $Name -Icon "!" -IconColor "Red" -Detail "SECURITE : chemin refuse (trop proche de la racine du lecteur)" -DetailColor "Red"
        $null = $Actions.Add("$Name : SECURITE - chemin refuse ($Path)")
        return
    }
    if ($SkipTargets -and ($SkipTargets -contains $Name)) {
        $null = $script:SkipTargetsMatched.Add($Name)
        Write-TargetLine -Prefix $prefix -Name $Name -Icon "»" -IconColor "DarkGray" -Detail "ignore (-SkipTargets)"
        return
    }
    if ($OnlyTargets -and ($OnlyTargets -notcontains $Name)) {
        Write-TargetLine -Prefix $prefix -Name $Name -Icon "»" -IconColor "DarkGray" -Detail "ignore (hors -OnlyTargets)"
        return
    }
    if ($OnlyTargets) { $null = $script:OnlyTargetsMatched.Add($Name) }
    if (-not (Test-Path -LiteralPath $Path)) {
        Write-TargetLine -Prefix $prefix -Name $Name -Icon "·" -IconColor "DarkGray" -Detail "absent"
        return
    }

    $item = Get-Item -LiteralPath $Path -Force
    [int64]$before = 0
    if ($item.PSIsContainer) { $before = Get-FolderSizeBytes $Path } else { $before = $item.Length }

    if ($DryRun) {
        Write-TargetLine -Prefix $prefix -Name $Name -Icon "≈" -IconColor "Yellow" -Detail "simulation : $(Format-Size $before) seraient liberes" -DetailColor "Yellow"
        Add-Result $Name $before $before 0 $before
        $null = $Actions.Add("$Name : simulation ($(Format-Size $before))")
        return
    }

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    [int64]$after = 0
    [int]$count = 0
    [int]$remaining = 0

    if ($item.PSIsContainer) {
        $rd = Remove-DirectoryFast -Path $Path
        $count = $rd.Removed
        $remaining = $rd.Remaining
        $after = Get-FolderSizeBytes $Path
    } else {
        Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $Path) {
            $after = (Get-Item -LiteralPath $Path -Force).Length
            $count = 0
            $remaining = 1
        } else {
            $after = 0
            $count = 1
            $remaining = 0
        }
    }
    $sw.Stop()

    [int64]$gain = [math]::Max(0L, $before - $after)
    Add-Result $Name $before $after $count $null $sw.ElapsedMilliseconds $remaining
    $script:TotalFilesRemoved += $count

    if ($count -eq 0 -and $remaining -gt 0) {
        # Verrouillage total : le dossier/fichier avait du contenu, la tentative de
        # suppression n'a rien enleve du tout. Distinct de "rien a nettoyer" (qui
        # signifie que la cible etait deja vide avant meme de tenter quoi que ce soit).
        $null = $Actions.Add("$Name : verrouille ($remaining element(s) non supprime(s))")
        Write-TargetLine -Prefix $prefix -Name $Name -Icon "!" -IconColor "Red" -Detail "non supprime - verrouille ou protege ($remaining element(s))" -DetailColor "Red"
    } elseif ($remaining -gt 0 -and $count -gt 0) {
        # Verrouillage partiel : une partie a ete supprimee, le reste est bloque
        # (fichiers ouverts par un processus au moment du nettoyage).
        $line = "{0} supprime(s), {1} verrouille(s)/protege(s)   {2} -> {3}  (gain {4}, {5} ms)" -f $count, $remaining, (Format-Size $before), (Format-Size $after), (Format-Size $gain), $sw.ElapsedMilliseconds
        $null = $Actions.Add("$Name : nettoyage partiel ($count supprime(s), $remaining verrouille(s))")
        Write-TargetLine -Prefix $prefix -Name $Name -Icon "~" -IconColor "Yellow" -Detail $line -DetailColor "Yellow"
    } elseif ($count -gt 0 -or $gain -gt 0) {
        $detailTxt = "$count element(s)"
        $null = $Actions.Add("$Name nettoye ($detailTxt)")
        $line = "{0}   {1} -> {2}  (gain {3}, {4} ms)" -f $detailTxt, (Format-Size $before), (Format-Size $after), (Format-Size $gain), $sw.ElapsedMilliseconds
        Write-TargetLine -Prefix $prefix -Name $Name -Icon "✓" -IconColor "Green" -Detail $line -DetailColor "Gray"
    } else {
        $null = $Actions.Add("$Name : rien a nettoyer")
        Write-TargetLine -Prefix $prefix -Name $Name -Icon "-" -IconColor "DarkGray" -Detail "rien a nettoyer"
    }
}

function Show-Notification {
    param([string]$Title, [string]$Message)
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        Add-Type -AssemblyName System.Drawing -ErrorAction Stop
        $icon = New-Object System.Windows.Forms.NotifyIcon
        $icon.Icon = [System.Drawing.SystemIcons]::Information
        $icon.Visible = $true
        $icon.ShowBalloonTip(6000, $Title, $Message, [System.Windows.Forms.ToolTipIcon]::Info)
        Start-Sleep -Milliseconds 500
        $icon.Dispose()
    } catch {}
}

function Get-SparklineSvg {
    param([double[]]$Values, [string]$Color = '#4f8cff')
    if (-not $Values -or $Values.Count -lt 2) { return '' }
    $w = 260; $h = 44; $pad = 4
    $max = ($Values | Measure-Object -Maximum).Maximum
    $min = ($Values | Measure-Object -Minimum).Minimum
    if ($max -eq $min) { $max = $min + 1 }
    $stepX = ($w - 2 * $pad) / [math]::Max(1, ($Values.Count - 1))
    $pts = New-Object System.Collections.Generic.List[string]
    for ($i = 0; $i -lt $Values.Count; $i++) {
        $x = $pad + $i * $stepX
        $y = $h - $pad - ((($Values[$i] - $min) / ($max - $min)) * ($h - 2 * $pad))
        $ci = [System.Globalization.CultureInfo]::InvariantCulture
        $pts.Add($x.ToString("F1", $ci) + "," + $y.ToString("F1", $ci))
    }
    $pointsStr = [string]::Join(' ', $pts)
    return "<svg viewBox='0 0 $w $h' width='$w' height='$h' class='spark'><polyline points='$pointsStr' fill='none' stroke='$Color' stroke-width='2' stroke-linecap='round' stroke-linejoin='round'/></svg>"
}

function Invoke-SelfTest {
    Write-Host ""
    Write-Host "====================================================" -ForegroundColor Cyan
    Write-Host "  SelfTest - Nettoyage-Windows11 v5.2" -ForegroundColor Cyan
    Write-Host "====================================================" -ForegroundColor Cyan
    Write-Host ""

    $checks = New-Object System.Collections.ArrayList

    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    $null = $checks.Add([pscustomobject]@{ Test = "Droits administrateur";              Resultat = $isAdmin;                                                                                Warn = $false })
    $null = $checks.Add([pscustomobject]@{ Test = "robocopy.exe disponible";            Resultat = [bool](Get-Command robocopy.exe -ErrorAction SilentlyContinue);                        Warn = $false })
    $null = $checks.Add([pscustomobject]@{ Test = "DISM.exe disponible";                Resultat = [bool](Get-Command DISM.exe -ErrorAction SilentlyContinue);                            Warn = $false })
    $null = $checks.Add([pscustomobject]@{ Test = "Service wuauserv present";           Resultat = [bool](Get-Service wuauserv -ErrorAction SilentlyContinue);                            Warn = $false })
    $null = $checks.Add([pscustomobject]@{ Test = "Service FontCache present";          Resultat = [bool](Get-Service FontCache -ErrorAction SilentlyContinue);                          Warn = $false })

    # Checkpoint-Computer est un cmdlet WinPS 5.1, non charge a froid en PS7.
    # On tente un import via la couche de compatibilite avant le Get-Command.
    # Si introuvable meme apres import : WARN (pas FAIL) car cela n'affecte que -CreateRestorePoint.
    $checkpointAvail = [bool](Get-Command Checkpoint-Computer -ErrorAction SilentlyContinue)
    if (-not $checkpointAvail) {
        try {
            Import-Module Microsoft.PowerShell.Management -UseWindowsPowerShell -ErrorAction Stop
            $checkpointAvail = [bool](Get-Command Checkpoint-Computer -ErrorAction SilentlyContinue)
        } catch {}
    }
    $null = $checks.Add([pscustomobject]@{ Test = "Cmdlet Checkpoint-Computer (optionnel)"; Resultat = $checkpointAvail; Warn = $true })

    $reportWritable = $false
    try {
        if (-not (Test-Path $script:ReportFolder)) { New-Item -ItemType Directory -Path $script:ReportFolder -Force | Out-Null }
        $testFile = Join-Path $script:ReportFolder ("selftest_" + [guid]::NewGuid().ToString('N') + ".tmp")
        "test" | Out-File -LiteralPath $testFile -ErrorAction Stop
        Remove-Item -LiteralPath $testFile -Force -ErrorAction SilentlyContinue
        $reportWritable = $true
    } catch {}
    $null = $checks.Add([pscustomobject]@{ Test = "Dossier rapports inscriptible"; Resultat = $reportWritable; Warn = $false })

    # ------------------------------------------------------------------
    # Tests unitaires des fonctions internes (au-dela des prerequis systeme)
    # ------------------------------------------------------------------
    $selfTestTemp = Join-Path $env:TEMP ("NettoyageSelfTest_" + [guid]::NewGuid().ToString('N'))

    # Format-Size() : bornes octets / Ko / Mo
    $fmtOk = $true
    try {
        if ((Format-Size 0) -ne "0 octets") { $fmtOk = $false }
        if ((Format-Size 512) -notmatch "512") { $fmtOk = $false }
        if ((Format-Size 1024) -notmatch "1,00 Ko") { $fmtOk = $false }
        if ((Format-Size 1048576) -notmatch "1,00 Mo") { $fmtOk = $false }
    } catch { $fmtOk = $false }
    $null = $checks.Add([pscustomobject]@{ Test = "Format-Size() - bornes octets/Ko/Mo"; Resultat = $fmtOk; Warn = $false })

    # Format-Go() : conversion simple
    $fmtGoOk = $true
    try {
        if ((Format-Go 1.5) -notmatch "1,5") { $fmtGoOk = $false }
    } catch { $fmtGoOk = $false }
    $null = $checks.Add([pscustomobject]@{ Test = "Format-Go() - conversion"; Resultat = $fmtGoOk; Warn = $false })

    # Test-SafeCleanupPath() : le garde-fou de securite doit refuser les racines
    # et n'accepter que les chemins a 2+ niveaux sous la racine du lecteur.
    $guardOk = $true
    try {
        if ((Test-SafeCleanupPath "C:\") -ne $false) { $guardOk = $false }
        if ((Test-SafeCleanupPath "C:\Windows") -ne $false) { $guardOk = $false }
        if ((Test-SafeCleanupPath "C:\Users") -ne $false) { $guardOk = $false }
        if ((Test-SafeCleanupPath "") -ne $false) { $guardOk = $false }
        if ((Test-SafeCleanupPath $null) -ne $false) { $guardOk = $false }
        if ((Test-SafeCleanupPath "C:\Windows\Prefetch") -ne $true) { $guardOk = $false }
        if ((Test-SafeCleanupPath "C:\Windows\SoftwareDistribution\Download") -ne $true) { $guardOk = $false }
    } catch { $guardOk = $false }
    $null = $checks.Add([pscustomobject]@{ Test = "Test-SafeCleanupPath() - garde-fou racine"; Resultat = $guardOk; Warn = $false })

    # Get-FolderSizeBytes() : somme d'octets sur un dossier de test connu
    $folderSizeOk = $true
    try {
        New-Item -ItemType Directory -Path $selfTestTemp -Force | Out-Null
        "0123456789" | Out-File -LiteralPath (Join-Path $selfTestTemp "a.txt") -NoNewline -Encoding ascii
        "01234" | Out-File -LiteralPath (Join-Path $selfTestTemp "b.txt") -NoNewline -Encoding ascii
        $sz = Get-FolderSizeBytes $selfTestTemp
        if ($sz -ne 15) { $folderSizeOk = $false }
    } catch { $folderSizeOk = $false }
    $null = $checks.Add([pscustomobject]@{ Test = "Get-FolderSizeBytes() - somme sur dossier test"; Resultat = $folderSizeOk; Warn = $false })

    # Remove-DirectoryFast() : suppression complete d'un dossier non verrouille
    $removeFullOk = $true
    try {
        $rd = Remove-DirectoryFast -Path $selfTestTemp
        if ($rd.Removed -ne 2 -or $rd.Remaining -ne 0) { $removeFullOk = $false }
        if (Test-Path (Join-Path $selfTestTemp "a.txt")) { $removeFullOk = $false }
    } catch { $removeFullOk = $false }
    $null = $checks.Add([pscustomobject]@{ Test = "Remove-DirectoryFast() - suppression complete"; Resultat = $removeFullOk; Warn = $false })

    # Remove-DirectoryFast() : detection d'un fichier verrouille (coeur du fix v5.2
    # sur la distinction "rien a nettoyer" vs "verrouille"). On ouvre un FileStream
    # exclusif sur un fichier pour simuler une application qui le retient ouvert.
    $lockDetectOk = $true
    $lockedFileStream = $null
    try {
        New-Item -ItemType Directory -Path $selfTestTemp -Force | Out-Null
        $lockedFile = Join-Path $selfTestTemp "locked.txt"
        "verrouille" | Out-File -LiteralPath $lockedFile -NoNewline -Encoding ascii
        $lockedFileStream = [System.IO.File]::Open($lockedFile, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::None)
        $rd2 = Remove-DirectoryFast -Path $selfTestTemp
        if ($rd2.Removed -ne 0 -or $rd2.Remaining -ne 1) { $lockDetectOk = $false }
    } catch { $lockDetectOk = $false }
    finally {
        if ($lockedFileStream) { $lockedFileStream.Dispose() }
        try { Remove-Item -LiteralPath $selfTestTemp -Recurse -Force -ErrorAction SilentlyContinue } catch {}
    }
    $null = $checks.Add([pscustomobject]@{ Test = "Remove-DirectoryFast() - detection verrouillage"; Resultat = $lockDetectOk; Warn = $false })

    # Round-trip Baseline JSON (ecriture puis relecture, meme mecanisme que le run reel)
    $jsonRoundTripOk = $true
    try {
        $tmpBaseline = Join-Path $env:TEMP ("selftest_baseline_" + [guid]::NewGuid().ToString('N') + ".json")
        @{ Test = "valeur"; Nombre = 42 } | ConvertTo-Json | Out-File -LiteralPath $tmpBaseline -Encoding utf8 -Force
        $reread = Get-Content -LiteralPath $tmpBaseline -Raw | ConvertFrom-Json
        if ($reread.Nombre -ne 42) { $jsonRoundTripOk = $false }
        Remove-Item -LiteralPath $tmpBaseline -Force -ErrorAction SilentlyContinue
    } catch { $jsonRoundTripOk = $false }
    $null = $checks.Add([pscustomobject]@{ Test = "Round-trip Baseline JSON"; Resultat = $jsonRoundTripOk; Warn = $false })

    # Round-trip Historique CSV (delimiteur ';', meme convention que le run reel)
    $csvRoundTripOk = $true
    try {
        $tmpCsv = Join-Path $env:TEMP ("selftest_historique_" + [guid]::NewGuid().ToString('N') + ".csv")
        [pscustomobject]@{ Cible = "Test"; Gain = 123 } | Export-Csv -LiteralPath $tmpCsv -NoTypeInformation -Delimiter ';' -Encoding UTF8
        $rereadCsv = Import-Csv -LiteralPath $tmpCsv -Delimiter ';'
        if ($rereadCsv.Gain -ne "123") { $csvRoundTripOk = $false }
        Remove-Item -LiteralPath $tmpCsv -Force -ErrorAction SilentlyContinue
    } catch { $csvRoundTripOk = $false }
    $null = $checks.Add([pscustomobject]@{ Test = "Round-trip Historique CSV"; Resultat = $csvRoundTripOk; Warn = $false })

    # Detection LibreWolf : ne doit jamais lever d'exception, meme si le dossier
    # de profils est absent (utilisateur sans LibreWolf installe).
    $librewolfDetectOk = $true
    try {
        $lwRoot = Join-Path $env:APPDATA "LibreWolf\Profiles"
        $null = @(Get-ChildItem -Path $lwRoot -Directory -ErrorAction SilentlyContinue)
    } catch { $librewolfDetectOk = $false }
    $null = $checks.Add([pscustomobject]@{ Test = "Detection profils LibreWolf (sans exception)"; Resultat = $librewolfDetectOk; Warn = $false })

    # Detection Steam via registre : ne doit jamais lever d'exception, meme si
    # la cle HKCU:\Software\Valve\Steam est absente (Steam non installe).
    $steamDetectOk = $true
    try {
        $null = Get-ItemProperty -Path "HKCU:\Software\Valve\Steam" -ErrorAction SilentlyContinue
    } catch { $steamDetectOk = $false }
    $null = $checks.Add([pscustomobject]@{ Test = "Detection Steam via registre (sans exception)"; Resultat = $steamDetectOk; Warn = $false })


    foreach ($c in $checks) {
        if ($c.Resultat) {
            Write-Step ("  {0,-49} : PASS" -f $c.Test) "OK"
        } elseif ($c.Warn) {
            Write-Step ("  {0,-49} : WARN (optionnel)" -f $c.Test) "WARN"
        } else {
            Write-Step ("  {0,-49} : FAIL" -f $c.Test) "ERROR"
        }
    }

    $failCount = @($checks | Where-Object { -not $_.Resultat -and -not $_.Warn }).Count
    $warnCount = @($checks | Where-Object { -not $_.Resultat -and $_.Warn }).Count
    $script:SelfTestFailCount = $failCount
    Write-Host ""
    if ($failCount -eq 0 -and $warnCount -eq 0) {
        Write-Host "  Tous les tests sont passes." -ForegroundColor Green
    } elseif ($failCount -eq 0) {
        Write-Host "  $warnCount avertissement(s) optionnel(s) — aucun blocage." -ForegroundColor Yellow
    } else {
        Write-Host "  $failCount test(s) en echec, $warnCount avertissement(s)." -ForegroundColor Red
    }
    Write-Host ""
}

# ============================================================================
#  INITIALISATION
# ============================================================================
$StartTime  = Get-Date
$TimeStamp  = $StartTime.ToString("yyyy-MM-dd_HH-mm-ss")
$ReportFolder = "$env:USERPROFILE\Desktop\Rapports_Maintenance\Nettoyage système"
if (-not (Test-Path $ReportFolder)) { New-Item -ItemType Directory -Path $ReportFolder -Force | Out-Null }

$HtmlFile     = Join-Path $ReportFolder "Nettoyage-$TimeStamp.html"
$JsonFile     = Join-Path $ReportFolder "Nettoyage-$TimeStamp.json"
$HistoryFile  = Join-Path $ReportFolder "Historique_v5.csv"
$BaselineFile = Join-Path $ReportFolder "Baseline_v5.json"
$TranscriptFile = Join-Path $ReportFolder "Transcript-$TimeStamp.log"

if ($SelfTest) {
    Invoke-SelfTest
    if (-not $Silent) { Read-Host "  Appuyez sur ENTREE pour fermer" | Out-Null }
    $selfTestExitCode = 0
    if ($script:SelfTestFailCount -gt 0) { $selfTestExitCode = 1 }
    exit $selfTestExitCode
}

try { Start-Transcript -Path $TranscriptFile -ErrorAction SilentlyContinue | Out-Null } catch {}

$Results = New-Object System.Collections.ArrayList
$Actions = New-Object System.Collections.ArrayList
$script:StepCounter      = 0
$script:TotalFilesRemoved = 0
# Trace les noms de -OnlyTargets/-SkipTargets effectivement rencontres pendant
# le run, pour detecter en fin de parcours une faute de frappe qui ferait
# qu'un nom fourni ne correspond a aucune cible reelle (voir bloc de garde
# dans Clear-Target et le controle en fin de script).
$script:OnlyTargetsMatched = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
$script:SkipTargetsMatched = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)

Write-Host ""
Write-Host "====================================================" -ForegroundColor Magenta
Write-Host "   Nettoyage-Windows11 v5.2$(if($DryRun){' [MODE SIMULATION]'})" -ForegroundColor Magenta
Write-Host "====================================================" -ForegroundColor Magenta
Write-Host ""

# Baseline precedente (pour calcul du delta)
$PreviousBaseline = $null
if (Test-Path $BaselineFile) {
    try { $PreviousBaseline = Get-Content -LiteralPath $BaselineFile -Raw | ConvertFrom-Json } catch {}
}

# Historique precedent (pour la sparkline de tendance)
$PreviousHistoryRows = @()
if (Test-Path $HistoryFile) {
    try { $PreviousHistoryRows = Import-Csv -LiteralPath $HistoryFile -Delimiter ';' } catch {}
}

# ============================================================================
#  DETECTION DES CIBLES DYNAMIQUES
# ============================================================================
$LibreWolfProfilesRoot = Join-Path $env:APPDATA "LibreWolf\Profiles"
$LibreWolfProfiles = @()
if (Test-Path $LibreWolfProfilesRoot) {
    $LibreWolfProfiles = @(Get-ChildItem -Path $LibreWolfProfilesRoot -Directory -ErrorAction SilentlyContinue)
}

$SteamPath = $null
try {
    $regSteam = Get-ItemProperty -Path "HKCU:\Software\Valve\Steam" -ErrorAction SilentlyContinue
    if ($regSteam -and $regSteam.SteamPath -and (Test-Path $regSteam.SteamPath)) {
        $SteamPath = ($regSteam.SteamPath -replace '/', '\')
    }
} catch {}
$SteamSteps = if ($SteamPath) { 3 } else { 0 }

$OtherUserTempTargets = @()
try {
    $OtherUserDirs = Get-ChildItem "C:\Users" -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notin @($env:USERNAME, 'Public', 'Default', 'Default User', 'All Users') }
    foreach ($u in $OtherUserDirs) {
        $p = Join-Path $u.FullName "AppData\Local\Temp"
        if (Test-Path $p) { $OtherUserTempTargets += [pscustomobject]@{ Owner = $u.Name; Path = $p } }
    }
} catch {}

$script:TotalSteps = 39 + ($LibreWolfProfiles.Count * 2) + $OtherUserTempTargets.Count + $SteamSteps

# ============================================================================
#  ETAT DISQUE INITIAL
# ============================================================================
$DriveC = Get-PSDrive C
[int64]$FreeBeforeBytes = $DriveC.Free
$FreeBeforeGB = [math]::Round($FreeBeforeBytes / 1GB, 2)
Write-Step "Espace libre avant nettoyage : $(Format-Go $FreeBeforeGB) Go" "INFO"
Write-Host ""
Write-Host "  " -NoNewline
Write-Host "✓" -NoNewline -ForegroundColor Green
Write-Host " nettoye   " -NoNewline -ForegroundColor DarkGray
Write-Host "~" -NoNewline -ForegroundColor Yellow
Write-Host " partiel   " -NoNewline -ForegroundColor DarkGray
Write-Host "!" -NoNewline -ForegroundColor Red
Write-Host " verrouille/protege   " -NoNewline -ForegroundColor DarkGray
Write-Host "-" -NoNewline -ForegroundColor DarkGray
Write-Host " vide   " -NoNewline -ForegroundColor DarkGray
Write-Host "·" -NoNewline -ForegroundColor DarkGray
Write-Host " absent   " -NoNewline -ForegroundColor DarkGray
Write-Host "»" -NoNewline -ForegroundColor DarkGray
Write-Host " ignore" -ForegroundColor DarkGray
Write-Host ""

# ============================================================================
#  NETTOYAGE - WINDOWS UPDATE (arret/redemarrage service)
# ============================================================================
Write-Category "Windows Update"
try {
    if (-not $DryRun) { Stop-Service wuauserv -Force -ErrorAction SilentlyContinue }
    Clear-Target "Windows Update" "C:\Windows\SoftwareDistribution\Download"
} finally {
    if (-not $DryRun) { Start-Service wuauserv -ErrorAction SilentlyContinue }
}

# ============================================================================
#  NETTOYAGE - TEMPORAIRES & CACHES SYSTEME
# ============================================================================
Write-Category "Temporaires et caches systeme"
Clear-Target "Temp Utilisateur"        $env:TEMP
Clear-Target "Temp Windows"            "C:\Windows\Temp"
Clear-Target "DirectX Cache"           (Join-Path $env:LOCALAPPDATA "D3DSCache")
Clear-Target "Delivery Optimization"   "C:\Windows\SoftwareDistribution\DeliveryOptimization"
Clear-Target "Miniatures Explorer"     (Join-Path $env:LOCALAPPDATA "Microsoft\Windows\Explorer")
Clear-Target "WER ReportArchive"       "C:\ProgramData\Microsoft\Windows\WER\ReportArchive"
Clear-Target "WER ReportQueue"         "C:\ProgramData\Microsoft\Windows\WER\ReportQueue"
Clear-Target "WER Temp"                (Join-Path $env:LOCALAPPDATA "Microsoft\Windows\WER\Temp")
Clear-Target "CrashDumps"              (Join-Path $env:LOCALAPPDATA "CrashDumps")

# ============================================================================
#  NETTOYAGE - JOURNAUX (nouveau v5)
# ============================================================================
Write-Category "Journaux"
Clear-Target "Logs WindowsUpdate"  "C:\Windows\Logs\WindowsUpdate"
Clear-Target "Logs CBS"            "C:\Windows\Logs\CBS"
Clear-Target "Logs DISM"           "C:\Windows\Logs\DISM"
Clear-Target "Panther Setup Logs"  "C:\Windows\Panther"

# ============================================================================
#  NETTOYAGE - PREFETCH / DUMPS (nouveau v5)
# ============================================================================
Write-Category "Prefetch et dumps memoire"
Clear-Target "Prefetch"                "C:\Windows\Prefetch"
Clear-Target "Memory Dumps (Minidump)" "C:\Windows\Minidump"
Clear-Target "MEMORY.DMP"              "C:\Windows\MEMORY.DMP"

# ============================================================================
#  NETTOYAGE - CACHES SYSTEME UNITAIRES (nouveau v5, services arretes le temps du delete)
# ============================================================================
Write-Category "Caches systeme unitaires"
Clear-Target "IconCache.db" (Join-Path $env:LOCALAPPDATA "IconCache.db")

try {
    if (-not $DryRun) { Stop-Service FontCache -Force -ErrorAction SilentlyContinue }
    Clear-Target "FNTCACHE.DAT" "C:\Windows\System32\FNTCACHE.DAT"
} finally {
    if (-not $DryRun) { Start-Service FontCache -ErrorAction SilentlyContinue }
}

# ============================================================================
#  NETTOYAGE - OUTILS DE DEV (nouveau v5)
# ============================================================================
Write-Category "Outils de developpement"
Clear-Target "Cache npm"   (Join-Path $env:APPDATA "npm-cache")
Clear-Target "Cache pip"   (Join-Path $env:LOCALAPPDATA "pip\Cache")
Clear-Target "Cache cargo" (Join-Path $env:USERPROFILE ".cargo\registry\cache")
Clear-Target "VS Code Cache"       (Join-Path $env:APPDATA "Code\Cache")
Clear-Target "VS Code CachedData"  (Join-Path $env:APPDATA "Code\CachedData")
Clear-Target "VS Code Logs"        (Join-Path $env:APPDATA "Code\logs")
Clear-Target "VS Code GPUCache"    (Join-Path $env:APPDATA "Code\GPUCache")

# ============================================================================
#  NETTOYAGE - WEBVIEW2 (nouveau v5.1)
#  Composant Chromium independant d'Edge (toujours present meme si Edge est
#  desinstalle), utilise par Widgets, Teams, et diverses apps pour le rendu web
#  integre. Cache uniquement : se regenere automatiquement, sans risque.
# ============================================================================
Write-Category "WebView2"
Clear-Target "WebView2 Cache"      (Join-Path $env:LOCALAPPDATA "Microsoft\EdgeWebView\User Data\Default\Cache")
Clear-Target "WebView2 Code Cache" (Join-Path $env:LOCALAPPDATA "Microsoft\EdgeWebView\User Data\Default\Code Cache")
Clear-Target "WebView2 GPUCache"   (Join-Path $env:LOCALAPPDATA "Microsoft\EdgeWebView\User Data\Default\GPUCache")

# ============================================================================
#  NETTOYAGE - HISTORIQUE D'ACCES RECENTS (nouveau v5.1)
#  JumpLists (Demarrer/barre des taches) et MRU explorateur. Purement cosmetique/
#  vie privee, sans impact fonctionnel : recree automatiquement a l'usage.
# ============================================================================
Write-Category "Historique d'acces recents"
Clear-Target "JumpLists Automatiques" (Join-Path $env:APPDATA "Microsoft\Windows\Recent\AutomaticDestinations")
Clear-Target "JumpLists Manuelles"    (Join-Path $env:APPDATA "Microsoft\Windows\Recent\CustomDestinations")

# ============================================================================
#  NETTOYAGE - NVIDIA (nouveau v5)
# ============================================================================
Write-Category "NVIDIA"
Clear-Target "NVIDIA DXCache"    (Join-Path $env:LOCALAPPDATA "NVIDIA\DXCache")
Clear-Target "NVIDIA GLCache"    (Join-Path $env:LOCALAPPDATA "NVIDIA\GLCache")
Clear-Target "NVIDIA OptixCache" (Join-Path $env:LOCALAPPDATA "NVIDIA\OptixCache")

# ============================================================================
#  NETTOYAGE - SPOTIFY (nouveau v5)
# ============================================================================
Write-Category "Spotify"
Clear-Target "Spotify Storage Cache" (Join-Path $env:LOCALAPPDATA "Spotify\Storage")
Clear-Target "Spotify Data Cache"    (Join-Path $env:LOCALAPPDATA "Spotify\Data")

# ============================================================================
#  NETTOYAGE - STEAM (nouveau v5, conditionnel a la detection registre)
# ============================================================================
Write-Category "Steam"
if ($SteamPath) {
    Clear-Target "Steam AppCache"             (Join-Path $SteamPath "appcache")
    Clear-Target "Steam HtmlCache"            (Join-Path $SteamPath "htmlcache")
    Clear-Target "Steam Downloads incomplets" (Join-Path $SteamPath "steamapps\downloading")
} else {
    Write-Step "Steam : non detecte via le registre, cibles ignorees" "WARN"
}

# ============================================================================
#  NETTOYAGE - NAVIGATEURS
# ============================================================================
Write-Category "Navigateurs"
Clear-Target "Brave Cache"      (Join-Path $env:LOCALAPPDATA "BraveSoftware\Brave-Browser\User Data\Default\Cache")
Clear-Target "Brave Code Cache" (Join-Path $env:LOCALAPPDATA "BraveSoftware\Brave-Browser\User Data\Default\Code Cache")
Clear-Target "Brave GPU Cache"  (Join-Path $env:LOCALAPPDATA "BraveSoftware\Brave-Browser\User Data\Default\GPUCache")

foreach ($profile in $LibreWolfProfiles) {
    Clear-Target "LibreWolf Cache [$($profile.Name)]"        (Join-Path $profile.FullName "cache2")
    Clear-Target "LibreWolf StartupCache [$($profile.Name)]" (Join-Path $profile.FullName "startupCache")
}

# ============================================================================
#  NETTOYAGE - PROFILS TEMP MULTI-UTILISATEURS (nouveau v5)
# ============================================================================
if ($OtherUserTempTargets -and $OtherUserTempTargets.Count -gt 0) {
    Write-Category "Profils temp multi-utilisateurs"
    foreach ($t in $OtherUserTempTargets) {
        Clear-Target "Temp [$($t.Owner)]" $t.Path
    }
}

# ============================================================================
#  DNS & CORBEILLE
# ============================================================================
Write-Category "DNS et corbeille"
if ($DryRun) {
    Write-ActionLine -Name "Cache DNS" -Icon "≈" -IconColor "Yellow" -Detail "simulation : ignore" -DetailColor "Yellow"
    Write-ActionLine -Name "Corbeille" -Icon "≈" -IconColor "Yellow" -Detail "simulation : ignore" -DetailColor "Yellow"
} else {
    try {
        & ipconfig.exe /flushdns *> $null
        if ($LASTEXITCODE -eq 0) {
            Write-ActionLine -Name "Cache DNS" -Icon "✓" -IconColor "Green" -Detail "vide" -DetailColor "Gray"
            $null = $Actions.Add("Cache DNS vide")
        } else {
            Write-ActionLine -Name "Cache DNS" -Icon "~" -IconColor "Yellow" -Detail "code de sortie $LASTEXITCODE" -DetailColor "Yellow"
        }
    } catch {
        Write-ActionLine -Name "Cache DNS" -Icon "!" -IconColor "Red" -Detail "echec du vidage" -DetailColor "Red"
    }

    try {
        Clear-RecycleBin -Force -ErrorAction SilentlyContinue
        Write-ActionLine -Name "Corbeille" -Icon "✓" -IconColor "Green" -Detail "videe" -DetailColor "Gray"
        $null = $Actions.Add("Corbeille videe")
    } catch {
        Write-ActionLine -Name "Corbeille" -Icon "!" -IconColor "Red" -Detail "echec du vidage" -DetailColor "Red"
    }
}

# ============================================================================
#  POINT DE RESTAURATION (optionnel, nouveau v5)
# ============================================================================
if ($CreateRestorePoint) {
    Write-Category "Point de restauration systeme"
    if ($DryRun) {
        Write-ActionLine -Name "Point de restauration" -Icon "≈" -IconColor "Yellow" -Detail "simulation : ignore" -DetailColor "Yellow"
    } else {
        Write-Step "Creation d'un point de restauration systeme..."
        try {
            Enable-ComputerRestore -Drive "C:\" -ErrorAction SilentlyContinue
            Checkpoint-Computer -Description "Avant Nettoyage-Windows11 v5 ($TimeStamp)" -RestorePointType "MODIFY_SETTINGS" -ErrorAction Stop
            Write-ActionLine -Name "Point de restauration" -Icon "✓" -IconColor "Green" -Detail "cree" -DetailColor "Gray"
            $null = $Actions.Add("Point de restauration systeme cree")
        } catch {
            Write-ActionLine -Name "Point de restauration" -Icon "~" -IconColor "Yellow" -Detail "echec ou throttle Windows (1 max/24h) - $($_.Exception.Message)" -DetailColor "Yellow"
        }
    }
}

# ============================================================================
#  DISM - NETTOYAGE COMPOSANTS (avec ResetBase optionnel)
# ============================================================================
Write-Category "DISM - nettoyage composants"
if ($DryRun) {
    Write-ActionLine -Name "DISM StartComponentCleanup" -Icon "≈" -IconColor "Yellow" -Detail "simulation : non execute" -DetailColor "Yellow"
} else {
    if ($ResetBase -and -not $Silent) {
        Write-Host ""
        Write-Host "  ATTENTION : -ResetBase supprime DEFINITIVEMENT les anciennes versions" -ForegroundColor Red
        Write-Host "  des composants Windows (WinSxS). Plus aucun rollback de mise a jour" -ForegroundColor Red
        Write-Host "  ne sera possible apres cette operation." -ForegroundColor Red
        $confirmReset = Read-Host "  Confirmer le ResetBase ? [o/N]"
        if ($confirmReset -notmatch '^[Oo]') {
            Write-ActionLine -Name "ResetBase" -Icon "~" -IconColor "Yellow" -Detail "annule par l'utilisateur, StartComponentCleanup classique conserve" -DetailColor "Yellow"
            $ResetBase = $false
        }
    }

    Write-Step "DISM StartComponentCleanup$(if($ResetBase){' /ResetBase'}) en cours (peut prendre plusieurs minutes)..."
    try {
        $dismArgs = @('/Online', '/Cleanup-Image', '/StartComponentCleanup')
        if ($ResetBase) { $dismArgs += '/ResetBase' }
        & DISM.exe @dismArgs *> $null
        Write-ActionLine -Name "DISM StartComponentCleanup" -Icon "✓" -IconColor "Green" -Detail "termine" -DetailColor "Gray"
        $null = $Actions.Add("DISM StartComponentCleanup$(if($ResetBase){' /ResetBase'}) execute")
    } catch {
        Write-ActionLine -Name "DISM StartComponentCleanup" -Icon "!" -IconColor "Red" -Detail "echec - $($_.Exception.Message)" -DetailColor "Red"
    }
}

# ============================================================================
#  CALCULS FINAUX
# ============================================================================
Write-Host ""
$DriveC = Get-PSDrive C
[int64]$FreeAfterBytes = $DriveC.Free
$FreeAfterGB = [math]::Round($FreeAfterBytes / 1GB, 2)
$DiskGainGB  = [math]::Round([math]::Max(0L, $FreeAfterBytes - $FreeBeforeBytes) / 1GB, 2)

$RecoveredMeasure = $Results | Measure-Object -Property GainOctets -Sum
[int64]$RecoveredBytes = if ($RecoveredMeasure -and $null -ne $RecoveredMeasure.Sum) { $RecoveredMeasure.Sum } else { 0L }
$RecoveredGB = [math]::Round($RecoveredBytes / 1GB, 2)

$EndTime  = Get-Date
$Duration = "{0:mm} min {0:ss} s" -f ($EndTime - $StartTime)

Write-Step "Espace libre apres nettoyage : $(Format-Go $FreeAfterGB) Go (gain disque : $(Format-Go $DiskGainGB) Go)" "OK"
Write-Step "Volume total identifie comme nettoyable : $(Format-Go $RecoveredGB) Go" "OK"
Write-Step "Elements supprimes : $($script:TotalFilesRemoved)" "OK"
$LockedTargets = @($Results | Where-Object { $_.ElementsRestants -gt 0 })
if ($LockedTargets.Count -gt 0) {
    $lockedNames = ($LockedTargets | Select-Object -ExpandProperty Cible) -join ", "
    # ApresOctets d'une cible verrouillee correspond exactement a ce qui n'a pas
    # pu etre supprime (robocopy /MIR aurait tout enleve sinon) : c'est donc une
    # mesure fiable, pas une estimation, de l'espace bloque par le verrou/protection.
    $lockedMeasure = $LockedTargets | Measure-Object -Property ApresOctets -Sum
    $lockedBytes = if ($lockedMeasure -and $null -ne $lockedMeasure.Sum) { $lockedMeasure.Sum } else { 0L }
    Write-Step "Cibles avec elements non supprimes (verrouilles/proteges) : $($LockedTargets.Count) -> $lockedNames ($(Format-Size $lockedBytes) non recuperes)" "WARN"
}

# Detection de faute de frappe dans -OnlyTargets/-SkipTargets : si un nom fourni
# par l'utilisateur n'a matche aucune cible reelle pendant tout le run, c'est
# tres probablement une erreur de saisie qui a fait ignorer silencieusement le
# filtre pour ce nom (sans lever d'erreur PowerShell puisque -contains ne
# valide pas l'existence de la cible).
if ($OnlyTargets) {
    $unmatchedOnly = @($OnlyTargets | Where-Object { -not $script:OnlyTargetsMatched.Contains($_) })
    if ($unmatchedOnly.Count -gt 0) {
        Write-Step "ATTENTION -OnlyTargets : aucune cible ne correspond a '$($unmatchedOnly -join "', '")' (verifier l'orthographe)" "WARN"
    }
}
if ($SkipTargets) {
    $unmatchedSkip = @($SkipTargets | Where-Object { -not $script:SkipTargetsMatched.Contains($_) })
    if ($unmatchedSkip.Count -gt 0) {
        Write-Step "ATTENTION -SkipTargets : aucune cible ne correspond a '$($unmatchedSkip -join "', '")' (verifier l'orthographe)" "WARN"
    }
}

Write-Step "Duree totale : $Duration" "OK"
Write-Host ""

# Delta vs run precedent
$DeltaText = $null
if ($PreviousBaseline -and $PreviousBaseline.FreeAfterGB) {
    $deltaVal  = [math]::Round($FreeAfterGB - [double]$PreviousBaseline.FreeAfterGB, 2)
    $deltaSign = if ($deltaVal -ge 0) { '+' } else { '' }
    $DeltaText = "Evolution de l'espace libre depuis le run du $($PreviousBaseline.Date) : $deltaSign$(Format-Go $deltaVal) Go"
    Write-Step $DeltaText "INFO"
}

# ============================================================================
#  EXPORT BASELINE JSON (pour le delta du prochain run)
# ============================================================================
try {
    [pscustomobject]@{
        Date              = $StartTime.ToString("yyyy-MM-dd HH:mm:ss")
        Version           = "5.1"
        DiskGainGB        = $DiskGainGB
        RecoveredGB       = $RecoveredGB
        FichiersSupprimes = $script:TotalFilesRemoved
        FreeAfterGB       = $FreeAfterGB
        Duree             = $Duration
    } | ConvertTo-Json | Out-File -LiteralPath $BaselineFile -Encoding utf8 -Force
} catch {}

# ============================================================================
#  SPARKLINE DE TENDANCE (10 derniers runs)
# ============================================================================
$TrendValues = @()
try {
    $TrendValues = ($PreviousHistoryRows | Select-Object -Last 9 | ForEach-Object { [double]$_.GainDisqueGB })
} catch {}
$TrendValues += [double]$DiskGainGB
$SparklineSvg = Get-SparklineSvg -Values $TrendValues

# ============================================================================
#  EXPORT CSV HISTORIQUE
# ============================================================================
try {
    [pscustomobject]@{
        Date              = $StartTime.ToString("yyyy-MM-dd HH:mm:ss")
        Version           = "5.1"
        GainDisqueGB      = $DiskGainGB
        GainCumuleGB      = $RecoveredGB
        FichiersSupprimes = $script:TotalFilesRemoved
        EspaceLibreApresGB= $FreeAfterGB
        Duree             = $Duration
        ModeSimulation    = [bool]$DryRun
    } | Export-Csv -LiteralPath $HistoryFile -Append -NoTypeInformation -Delimiter ';' -Encoding UTF8
} catch {
    Write-Step "Historique CSV : echec de l'ecriture - $($_.Exception.Message)" "WARN"
}

# ============================================================================
#  EXPORT JSON COMPLET
# ============================================================================
try {
    [pscustomobject]@{
        Version            = "5.1"
        Date               = $StartTime.ToString("yyyy-MM-dd HH:mm:ss")
        Machine            = $env:COMPUTERNAME
        Utilisateur        = $env:USERNAME
        ModeSimulation     = [bool]$DryRun
        DureeSecondes      = [math]::Round(($EndTime - $StartTime).TotalSeconds, 1)
        EspaceLibreAvantGB = $FreeBeforeGB
        EspaceLibreApresGB = $FreeAfterGB
        GainDisqueGB       = $DiskGainGB
        GainCumuleGB       = $RecoveredGB
        FichiersSupprimes  = $script:TotalFilesRemoved
        PointRestauration  = [bool]$CreateRestorePoint
        ResetBaseUtilise   = [bool]$ResetBase
        Resultats          = $Results
        Actions            = $Actions
    } | ConvertTo-Json -Depth 6 | Out-File -LiteralPath $JsonFile -Encoding utf8 -Force
} catch {
    Write-Step "Export JSON : echec de l'ecriture - $($_.Exception.Message)" "WARN"
}

# ============================================================================
#  INFOS SYSTEME & TOP GAINS (pour le rapport HTML)
# ============================================================================
$OsCaption = "Windows"
$CpuName   = "N/A"
$RamGB     = 0.0
[int64]$DiskTotalBytes = 0

try {
    $osInfo = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
    if ($osInfo) { $OsCaption = "$($osInfo.Caption) - Build $($osInfo.BuildNumber)" }
} catch {}
try {
    $cpuInfo = Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cpuInfo) { $CpuName = $cpuInfo.Name.Trim() }
} catch {}
try {
    $csInfo = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue
    if ($csInfo) { $RamGB = [math]::Round($csInfo.TotalPhysicalMemory / 1GB, 1) }
} catch {}
try {
    $diskInfo = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'" -ErrorAction SilentlyContinue
    if ($diskInfo) { $DiskTotalBytes = [int64]$diskInfo.Size }
} catch {}

$DiskTotalGB     = if ($DiskTotalBytes -gt 0) { [math]::Round($DiskTotalBytes / 1GB, 1) } else { 0 }
$DiskUsedPercent = if ($DiskTotalBytes -gt 0) { [math]::Round((($DiskTotalBytes - $FreeAfterBytes) / $DiskTotalBytes) * 100, 1) } else { 0 }
$DiskGainPercent = if ($DiskTotalBytes -gt 0) { [math]::Round(($RecoveredBytes / $DiskTotalBytes) * 100, 2) } else { 0 }

$TopGains = @($Results | Where-Object { $_.GainOctets -gt 0 } | Sort-Object -Property GainOctets -Descending | Select-Object -First 5)

# ============================================================================
#  RAPPORT HTML
# ============================================================================
$RowsHtml = New-Object System.Collections.Generic.List[string]
foreach ($r in $Results) {
    # Meme logique de classification que Clear-Target en console (coherence
    # console/HTML) : distingue nettoye / partiel / verrouille / vide / simulation,
    # au lieu du seul critere "GainOctets=0 et ElementsSupprimes=0" qui confondait
    # "dossier deja vide" et "verrouille, rien n'a pu etre supprime".
    $remaining = if ($r.PSObject.Properties.Name -contains 'ElementsRestants') { $r.ElementsRestants } else { 0 }
    if ($DryRun) {
        if ($r.GainOctets -gt 0) {
            $rowClass = " class='row-partial'"
            $statusBadge = "<span class='status-badge status-sim' title='Simulation'>&#8776;</span>"
        } else {
            $rowClass = " class='row-empty'"
            $statusBadge = "<span class='status-badge status-empty' title='Vide'>-</span>"
        }
    } elseif ($remaining -gt 0 -and $r.ElementsSupprimes -eq 0) {
        $rowClass = " class='row-locked'"
        $statusBadge = "<span class='status-badge status-locked' title='Verrouille ou protege'>&#33;</span>"
    } elseif ($remaining -gt 0 -and $r.ElementsSupprimes -gt 0) {
        $rowClass = " class='row-partial'"
        $statusBadge = "<span class='status-badge status-partial' title='Partiellement nettoye'>~</span>"
    } elseif ($r.ElementsSupprimes -gt 0 -or $r.GainOctets -gt 0) {
        $rowClass = ""
        $statusBadge = "<span class='status-badge status-ok' title='Nettoye'>&#10003;</span>"
    } else {
        $rowClass = " class='row-empty'"
        $statusBadge = "<span class='status-badge status-empty' title='Vide'>-</span>"
    }
    $gainClass = if ($r.GainOctets -gt 0) { "gain-pos" } else { "gain-zero" }
    $dureeTxt = if ($r.DureeMs -gt 0) { "$($r.DureeMs) ms" } else { "-" }
    $RowsHtml.Add("<tr$rowClass><td class='num'>$statusBadge</td><td>$(He $r.Cible)</td><td class='num'>$(He $r.AvantFormate)</td><td class='num'>$(He $r.ApresFormate)</td><td class='num $gainClass'>$(He $r.GainFormate)</td><td class='num'>$($r.ElementsSupprimes)</td><td class='num'>$(He $dureeTxt)</td></tr>")
}
$ResultsTableRows = [string]::Join("`n", $RowsHtml)
if ($Results.Count -eq 0) {
    # Meme logique de repli que la section "Top gains" (Aucun gain significatif)
    # pour un tableau totalement vide : arrive si -OnlyTargets ne correspond a
    # aucune cible (typo) ou si -SkipTargets exclut tout, plutot qu'un corps de
    # tableau vide sans explication.
    $emptyReason = if ($OnlyTargets) { "aucune cible ne correspond a -OnlyTargets (verifier l'orthographe)" } elseif ($SkipTargets) { "toutes les cibles ont ete exclues par -SkipTargets" } else { "aucune cible traitee" }
    $ResultsTableRows = "<tr><td colspan='7' style='text-align:center; color: var(--muted); padding: 20px;'>Aucune cible traitee - $(He $emptyReason)</td></tr>"
}

$ActionsHtml = New-Object System.Collections.Generic.List[string]
foreach ($a in $Actions) {
    if ($a -match ' : verrouille ') {
        $ActionsHtml.Add("<li class='action-locked'><span class='action-icon'>&#33;</span>$(He $a)</li>")
    } elseif ($a -match 'nettoyage partiel') {
        $ActionsHtml.Add("<li class='action-partial'><span class='action-icon'>~</span>$(He $a)</li>")
    } elseif ($a -match ' : simulation ') {
        $ActionsHtml.Add("<li class='action-sim'><span class='action-icon'>&#8776;</span>$(He $a)</li>")
    } elseif ($a -match 'rien a nettoyer') {
        $ActionsHtml.Add("<li class='action-neutral'><span class='action-icon'>&#9675;</span>$(He $a)</li>")
    } else {
        $ActionsHtml.Add("<li class='action-ok'><span class='action-icon'>&#10003;</span>$(He $a)</li>")
    }
}
$ActionsListItems = [string]::Join("`n", $ActionsHtml)

$TopGainsHtml = New-Object System.Collections.Generic.List[string]
foreach ($g in $TopGains) {
    $TopGainsHtml.Add("<li><span class='top-gain-name'>$(He $g.Cible)</span><span class='top-gain-size'>$(He $g.GainFormate)</span></li>")
}
if ($TopGainsHtml.Count -eq 0) {
    $TopGainsHtml.Add("<li><span class='top-gain-name'>Aucun gain significatif sur ce run</span></li>")
}
$TopGainsListItems = [string]::Join("`n", $TopGainsHtml)

$DeltaBlockHtml = ""
if ($DeltaText) {
    $DeltaBlockHtml = "<div class='card-sub'>$(He $DeltaText)</div>"
}

$DryRunBadgeHtml = ""
if ($DryRun) {
    $DryRunBadgeHtml = "<span class='badge-sim'>MODE SIMULATION</span>"
}

$SparklineSectionHtml = ""
if ($SparklineSvg) {
    $SparklineSectionHtml = @"
<div class="section-title">Tendance (10 derniers runs)</div>
<div class="card">$SparklineSvg</div>
"@
}

$Html = @"
<!DOCTYPE html>
<html lang="fr">
<head>
<meta charset="utf-8">
<title>Rapport Nettoyage - $env:COMPUTERNAME</title>
<style>
  :root {
    --bg:        #0d1117;
    --surface:   #161b22;
    --surface2:  #1f2937;
    --border:    #30363d;
    --accent:    #3b82f6;
    --accent2:   #22d3ee;
    --green:     #22c55e;
    --yellow:    #eab308;
    --red:       #ef4444;
    --text:      #e6edf3;
    --muted:     #8b949e;
    --radius:    10px;
  }
  *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }
  body {
    font-family: 'Segoe UI', system-ui, sans-serif;
    background: var(--bg);
    color: var(--text);
    font-size: 14px;
    line-height: 1.6;
    padding: 28px 20px;
  }
  .wrap { max-width: 960px; margin: 0 auto; }

  .header {
    display: flex; align-items: center; gap: 16px;
    border-bottom: 1px solid var(--border);
    padding-bottom: 20px; margin-bottom: 24px;
  }
  .header-icon {
    width: 48px; height: 48px; border-radius: 12px;
    background: linear-gradient(135deg, var(--accent), var(--accent2));
    display: flex; align-items: center; justify-content: center;
    font-size: 22px; flex-shrink: 0;
  }
  .header h1 { font-size: 22px; font-weight: 700; letter-spacing: -.3px; }
  .header .sub { color: var(--muted); font-size: 12px; margin-top: 2px; }
  .badge-sim {
    background-color: #b35900; color: #fff;
    padding: 3px 9px; border-radius: 6px;
    font-size: 12px; margin-left: 10px; vertical-align: middle;
  }

  .grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(200px, 1fr)); gap: 14px; margin-bottom: 20px; }
  .card {
    background: var(--surface); border: 1px solid var(--border);
    border-radius: var(--radius); padding: 18px 20px;
  }
  .card.wide { grid-column: 1 / -1; }
  .card-label { font-size: 11px; color: var(--muted); text-transform: uppercase; letter-spacing: .06em; margin-bottom: 6px; }
  .card-value { font-size: 28px; font-weight: 700; line-height: 1.1; }
  .card-value.accent  { color: var(--accent2); }
  .card-value.green   { color: var(--green); }
  .card-sub { font-size: 12px; color: var(--muted); margin-top: 4px; }

  .disk-bar-wrap { margin-top: 12px; }
  .disk-bar-labels { display: flex; justify-content: space-between; font-size: 11px; color: var(--muted); margin-bottom: 5px; }
  .disk-bar-track { height: 8px; background: var(--surface2); border-radius: 4px; overflow: hidden; }
  .disk-bar-used  { height: 100%; background: var(--border); border-radius: 4px; position: relative; }
  .disk-bar-gain  { position: absolute; right: 0; top: 0; height: 100%; background: linear-gradient(90deg, var(--accent), var(--accent2)); border-radius: 4px; }

  .section-title {
    font-size: 13px; font-weight: 600; color: var(--muted);
    text-transform: uppercase; letter-spacing: .06em;
    margin: 24px 0 12px;
  }

  table { width: 100%; border-collapse: collapse; }
  th {
    background: var(--surface2); color: var(--muted);
    font-size: 11px; font-weight: 600;
    text-transform: uppercase; letter-spacing: .05em;
    padding: 10px 12px; text-align: left;
    border-bottom: 1px solid var(--border);
  }
  td { padding: 9px 12px; border-bottom: 1px solid var(--border); vertical-align: middle; }
  tr:last-child td { border-bottom: none; }
  tr:hover td { background: var(--surface2); }
  .num { text-align: right; font-variant-numeric: tabular-nums; font-size: 13px; }
  .gain-pos  { color: var(--green); font-weight: 600; }
  .gain-zero { color: var(--muted); }
  tr.row-empty td { color: var(--muted); opacity: .55; }
  tr.row-empty:hover td { opacity: 1; }
  tr.row-locked td { border-left: 3px solid var(--red); }
  tr.row-partial td { border-left: 3px solid var(--yellow); }
  .status-badge { display: inline-flex; align-items: center; justify-content: center; width: 18px; height: 18px; border-radius: 4px; font-size: 12px; font-weight: 700; }
  .status-ok      { color: var(--green); }
  .status-locked  { color: var(--red); }
  .status-partial { color: var(--yellow); }
  .status-empty   { color: var(--muted); }
  .status-sim     { color: var(--yellow); }
  .status-legend { display: flex; flex-wrap: wrap; gap: 16px; margin: -6px 0 14px 2px; font-size: 12px; color: var(--muted); }
  .status-legend span { display: inline-flex; align-items: center; gap: 5px; }

  .action-list { list-style: none; display: flex; flex-direction: column; gap: 6px; }
  .action-list li {
    padding: 7px 12px; background: var(--surface2);
    border-radius: 6px; font-size: 13px;
    display: flex; align-items: center; gap: 8px;
  }
  .action-list li.action-ok { color: var(--text); border-left: 3px solid var(--green); }
  .action-list li.action-neutral { color: var(--muted); border-left: 3px solid var(--border); }
  .action-list li.action-locked { color: var(--text); border-left: 3px solid var(--red); }
  .action-list li.action-partial { color: var(--text); border-left: 3px solid var(--yellow); }
  .action-list li.action-sim { color: var(--muted); border-left: 3px solid var(--yellow); }
  .action-icon { font-size: 12px; flex-shrink: 0; width: 14px; text-align: center; }
  .action-ok .action-icon { color: var(--green); }
  .action-neutral .action-icon { color: var(--muted); }
  .action-locked .action-icon { color: var(--red); }
  .action-partial .action-icon { color: var(--yellow); }
  .action-sim .action-icon { color: var(--yellow); }

  .top-gains-list { list-style: none; display: flex; flex-direction: column; gap: 6px; }
  .top-gains-list li {
    display: flex; justify-content: space-between; align-items: center;
    padding: 8px 12px; background: var(--surface2);
    border-radius: 6px; font-size: 13px;
    border-left: 3px solid var(--accent2);
  }
  .top-gain-name { color: var(--text); }
  .top-gain-size { color: var(--green); font-weight: 600; font-variant-numeric: tabular-nums; }

  .spark { display: block; }

  .filter-box {
    width: 100%; box-sizing: border-box; padding: 9px 12px; margin-bottom: 12px;
    background: var(--surface2); border: 1px solid var(--border); border-radius: 6px;
    color: var(--text); font-size: 13px; font-family: inherit;
  }
  .filter-box:focus { outline: none; border-color: var(--accent); }
  .filter-box::placeholder { color: var(--muted); }

  .footer { margin-top: 30px; padding-top: 14px; border-top: 1px solid var(--border); color: var(--muted); font-size: 11px; text-align: center; }
  @media (max-width: 700px) {
    .grid { grid-template-columns: 1fr; }
  }
</style>
</head>
<body>
<div class="wrap">

  <div class="header">
    <div class="header-icon">&#129529;</div>
    <div>
      <h1>Rapport Nettoyage Windows 11 $DryRunBadgeHtml</h1>
      <div class="sub">$env:COMPUTERNAME - $OsCaption - $TimeStamp</div>
    </div>
  </div>

  <div class="grid">
    <div class="card">
      <div class="card-label">Gain mesure (disque C:)</div>
      <div class="card-value accent">$(Format-Go $DiskGainGB) Go</div>
      <div class="card-sub">Espace libre : $(Format-Go $FreeBeforeGB) Go &rarr; $(Format-Go $FreeAfterGB) Go</div>
      $DeltaBlockHtml
    </div>
    <div class="card">
      <div class="card-label">Gain cumule (dossiers)</div>
      <div class="card-value green">$(Format-Go $RecoveredGB) Go</div>
      <div class="card-sub">Somme des gains par cible</div>
    </div>
    <div class="card">
      <div class="card-label">Elements supprimes</div>
      <div class="card-value">$($script:TotalFilesRemoved)</div>
      <div class="card-sub">Fichiers &amp; dossiers</div>
    </div>
    <div class="card">
      <div class="card-label">Duree</div>
      <div class="card-value">$Duration</div>
      <div class="card-sub">Demarre $($StartTime.ToString('HH:mm:ss'))</div>
    </div>

    <div class="card wide">
      <div class="card-label">Utilisation disque C: apres nettoyage</div>
      <div class="disk-bar-wrap">
        <div class="disk-bar-labels">
          <span>0</span>
          <span>$(Format-Pct $DiskUsedPercent) % utilise - $(Format-Go $FreeAfterGB) Go libres sur $(Format-Go $DiskTotalGB) Go</span>
          <span>$(Format-Go $DiskTotalGB) Go</span>
        </div>
        <div class="disk-bar-track">
          <div class="disk-bar-used" style="width:$(Format-NumInvariant $DiskUsedPercent)%">
            <div class="disk-bar-gain" style="width:$(Format-NumInvariant $DiskGainPercent)%"></div>
          </div>
        </div>
        <div class="card-sub" style="margin-top:6px">La portion en degrade represente l'espace recupere lors de ce nettoyage ($(Format-Pct $DiskGainPercent) % du disque total)</div>
      </div>
    </div>
  </div>

$SparklineSectionHtml

  <div class="section-title">Top gains</div>
  <div class="card">
    <ul class="top-gains-list">
$TopGainsListItems
    </ul>
  </div>

  <div class="section-title">Systeme</div>
  <div class="card">
    <table>
      <tr><th>OS</th><th>CPU</th><th>RAM</th><th>Machine</th><th>Utilisateur</th></tr>
      <tr>
        <td>$(He $OsCaption)</td>
        <td>$(He $CpuName)</td>
        <td class="num">$("{0:N1}" -f $RamGB) Go</td>
        <td>$(He $env:COMPUTERNAME)</td>
        <td>$(He $env:USERNAME)</td>
      </tr>
    </table>
  </div>

  <div class="section-title">Detail par cible ($($Results.Count) cibles traitees)</div>
  <div class="status-legend">
    <span><span class="status-badge status-ok">&#10003;</span> Nettoye</span>
    <span><span class="status-badge status-partial">~</span> Partiel</span>
    <span><span class="status-badge status-locked">&#33;</span> Verrouille/protege</span>
    <span><span class="status-badge status-empty">-</span> Vide</span>
    <span><span class="status-badge status-sim">&#8776;</span> Simulation (-DryRun)</span>
  </div>
  <div class="card">
    <input type="text" id="filterInput" onkeyup="filterTable()" placeholder="Filtrer par nom de cible..." class="filter-box">
    <table id="resultsTable">
      <thead>
        <tr>
          <th></th>
          <th>Cible</th>
          <th style="text-align:right">Avant</th>
          <th style="text-align:right">Apres</th>
          <th style="text-align:right">Gain</th>
          <th style="text-align:right">Elements</th>
          <th style="text-align:right">Duree</th>
        </tr>
      </thead>
      <tbody>
$ResultsTableRows
      </tbody>
    </table>
  </div>

  <div class="section-title">Journal des actions ($($Actions.Count))</div>
  <div class="card">
    <ul class="action-list">
$ActionsListItems
    </ul>
  </div>

  <div class="footer">
    Nettoyage-Windows11 v5.2 - Genere le $($EndTime.ToString('dd/MM/yyyy a HH:mm:ss')) -
    JSON : $(Split-Path $JsonFile -Leaf) - Historique : $(Split-Path $HistoryFile -Leaf)
  </div>

</div>
<script>
function filterTable() {
  var input = document.getElementById("filterInput");
  var filter = input.value.toLowerCase();
  var table = document.getElementById("resultsTable");
  var rows = table.getElementsByTagName("tbody")[0].getElementsByTagName("tr");
  for (var i = 0; i < rows.length; i++) {
    var cell = rows[i].getElementsByTagName("td")[1];
    if (cell) {
      var txt = cell.textContent || cell.innerText;
      rows[i].style.display = txt.toLowerCase().indexOf(filter) > -1 ? "" : "none";
    }
  }
}
</script>
</body>
</html>
"@

try {
    $Html | Out-File -LiteralPath $HtmlFile -Encoding utf8 -Force
    Write-Step "Rapport HTML genere : $HtmlFile" "OK"
} catch {
    Write-Step "Rapport HTML : echec de l'ecriture - $($_.Exception.Message)" "ERROR"
}

# ============================================================================
#  PURGE DES ANCIENS RAPPORTS (nouveau v5.1)
#  Le CSV d'historique (Historique_v5.csv) et la baseline (Baseline_v5.json) ne
#  sont jamais purges : ils alimentent la tendance et le delta inter-runs.
# ============================================================================
if ($RetainReportsDays -gt 0) {
    try {
        $cutoff = (Get-Date).AddDays(-$RetainReportsDays)
        $oldReports = Get-ChildItem -Path $ReportFolder -File -ErrorAction SilentlyContinue |
            Where-Object {
                $_.LastWriteTime -lt $cutoff -and
                ($_.Name -like "Nettoyage-*.html" -or $_.Name -like "Nettoyage-*.json" -or $_.Name -like "Transcript-*.log")
            }
        if ($oldReports) {
            $purgedCount = 0
            foreach ($f in $oldReports) {
                try { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop; $purgedCount++ } catch {}
            }
            if ($purgedCount -gt 0) {
                Write-Step "Purge des rapports : $purgedCount fichier(s) de plus de $RetainReportsDays jour(s) supprime(s)" "OK"
                $null = $Actions.Add("Purge automatique : $purgedCount ancien(s) rapport(s) supprime(s) (retention $RetainReportsDays j)")
            }
        }
    } catch {
        Write-Step "Purge des rapports : echec - $($_.Exception.Message)" "WARN"
    }
}

# ============================================================================
#  NOTIFICATION & CLOTURE
# ============================================================================
Show-Notification -Title "Nettoyage Windows 11 termine" -Message "Gain disque : $(Format-Go $DiskGainGB) Go | Elements supprimes : $($script:TotalFilesRemoved) | Duree : $Duration"

Write-Host ""
if (-not $Silent) {
    $openBrowser = Read-Host "Ouvrir le rapport dans le navigateur ? [O/n]"
    if ($openBrowser -notmatch '^[Nn]') {
        try { Start-Process $HtmlFile } catch {}
    }
}
# En mode -Silent (ex: tache planifiee), le rapport n'est pas ouvert automatiquement.

try { Stop-Transcript | Out-Null } catch {}

if (-not $Silent) {
    Write-Host ""
    Write-Host "====================================================" -ForegroundColor Magenta
    Read-Host "Appuyez sur ENTREE pour fermer"
}

$finalExitCode = 0
if ($LockedTargets.Count -gt 0) { $finalExitCode = 1 }
exit $finalExitCode

# SIG # Begin signature block
# MIIFwgYJKoZIhvcNAQcCoIIFszCCBa8CAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCDOsiHs/4zaWw4e
# che0fpjrGV0tjYvDIyFYhAar7+fppqCCAygwggMkMIICDKADAgECAhB6X4r8AlBU
# p0MV3JpMuQ6sMA0GCSqGSIb3DQEBCwUAMCoxKDAmBgNVBAMMH05lcGhyZW4gUG93
# ZXJTaGVsbCBDb2RlIFNpZ25pbmcwHhcNMjYwNzA0MDIzMzIwWhcNMzEwNzA0MDI0
# MzIwWjAqMSgwJgYDVQQDDB9OZXBocmVuIFBvd2VyU2hlbGwgQ29kZSBTaWduaW5n
# MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEA1JnV5AocUnAMNIG3nYF9
# 5mOQz5NzMYJqc9D6mq3pjRlmuYIgvYEuJL5dvt8eoAiUKd+XHTaY5wl+zt7LUon+
# TmEldVwfrYvROpI+5TDyBRc5BzY4uACsA4JUM4ienjX04BBKT3uH6JwHzBluWqcG
# Xrg16NqzDiae7WNzVrev+BME00mgSvBo3hKp3sHIvFQaAmjGXLyJd+llfnBpmoD9
# JnOxMKO7VFIlhAz5cEUnFu/xDLHgARdBUfXA5odScWKiDvygNZsH1vHo07Oo7pDK
# awR3bT6lcXWRXSUmawgE1mZra+b9qpeNol+5J+86zN83RccBKZBUtQQoyy+cv20x
# VQIDAQABo0YwRDAOBgNVHQ8BAf8EBAMCB4AwEwYDVR0lBAwwCgYIKwYBBQUHAwMw
# HQYDVR0OBBYEFNxVaDYoNv8UXQWnbtEy/DTaQHjYMA0GCSqGSIb3DQEBCwUAA4IB
# AQCE4NqZbeximmbNEORyLxvIYiMQwP59B9R95blQQ/zugPSt4wab61yBbgO1E3mH
# mUdN0fCHhN/u0uB7h7ZBYw1w4hnzoiBac4UYzsXH4/D41gBjutbtDllRy6/zs3dl
# /hbbHAmwKXdjNVLG9cPkpWlkvKR1DJLMugU2uj+S6k+U7DfHo76sbAKqiu3biXtd
# mao6PP99EU7JBYZjsJ+BsnYcZ2KcnZ8TKiRuhSXoxAyPman7Z0BVo1H2O+fxd96b
# 4W8VclmpFh7T2CyRAHolwEy5coFYyueisO0PZg+nKwXr66+m1T1CBLQYwh79/SKO
# wGUJyU5RtTryD+hfLwkTQKVCMYIB8DCCAewCAQEwPjAqMSgwJgYDVQQDDB9OZXBo
# cmVuIFBvd2VyU2hlbGwgQ29kZSBTaWduaW5nAhB6X4r8AlBUp0MV3JpMuQ6sMA0G
# CWCGSAFlAwQCAQUAoIGEMBgGCisGAQQBgjcCAQwxCjAIoAKAAKECgAAwGQYJKoZI
# hvcNAQkDMQwGCisGAQQBgjcCAQQwHAYKKwYBBAGCNwIBCzEOMAwGCisGAQQBgjcC
# ARUwLwYJKoZIhvcNAQkEMSIEIIZuutiD7nt9NNNOx/KQKWwGnxSd5v8lw95sSR/8
# Kcl3MA0GCSqGSIb3DQEBAQUABIIBANBkSnFp3TZk0HUnsHAgYq/S/yBaIhzrIbIg
# j3uGByISs9T8ATaVDKcI9TYBuBLgbs+pn+wJq9n2nwCiA2lmK89xXPUOH8gL6Pwk
# siPQz62w9sHV+9bfwtlgvHx8fJ3v/zmbJ1F4F16uM6DqZx8sIaX73oovcT4wOdB6
# yqg/KIou0a0TdVYlOYZCZ6SbX2tIz/50GD5R8QVHTvfqUZkzoS3075+6DDXKgM6o
# ItTLXWlheOm4IsjhiZ7FKxbH/c0IOOu7+dwHCScVyd6TcIyhn1DWThJGtIrsnlkK
# WCUlQjLTNXwsgxTK0dZ6uaIplja580sel7W2p+8Wgjp+21MaADs=
# SIG # End signature block
