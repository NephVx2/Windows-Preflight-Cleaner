#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Windows-Preflight-Cleaner v5.3.0 - Windows 11 maintenance and cleanup suite

.DESCRIPTION
    Cleans system and application caches, stale logs, multi-user temp files and
    WinSxS components. Generates an HTML report (dark theme, dashboard-style:
    summary tiles, disk usage bar, Top Gains, system info, trend across recent
    runs, duration per target), a CSV history export, a complete JSON export,
    and a JSON baseline enabling a delta calculation against the previous run.
    Automatically purges old reports beyond -RetainReportsDays.

.PARAMETER Silent
    Suppresses interactive prompts (ResetBase confirmation, ENTER pause) and
    does not automatically open the HTML report in the browser (useful for a
    scheduled task).

.PARAMETER DryRun
    Simulation mode: computes potential gains without deleting anything or
    running DISM.

.PARAMETER SelfTest
    Checks prerequisites (admin rights, robocopy, DISM, reports folder write
    access, services) then exits without performing any cleanup.

.PARAMETER CreateRestorePoint
    Creates a system restore point before the DISM cleanup (subject to
    Windows' 1 point/24h throttle for the MODIFY_SETTINGS type).

.PARAMETER ResetBase
    Adds /ResetBase to the DISM cleanup: PERMANENTLY removes old versions of
    WinSxS components (no more update rollback possible). Asks for interactive
    confirmation unless -Silent is used.

.PARAMETER SkipTargets
    List of target names to skip (see the names shown in the console, e.g.
    "npm Cache").

.PARAMETER OnlyTargets
    List of target names to process exclusively (all others are skipped).

.PARAMETER RetainReportsDays
    Number of days to retain HTML/JSON/Transcript reports before automatic
    purge at the end of the run (default: 60). The history CSV and the JSON
    baseline are never purged. Use -RetainReportsDays 0 to disable the purge.

.EXAMPLE
    .\Windows-Preflight-Cleaner.ps1 -DryRun
    Full simulation with no deletions, to preview the gains.

.EXAMPLE
    .\Windows-Preflight-Cleaner.ps1 -Silent -SkipTargets "Prefetch","Steam AppCache"
    Silent run (scheduled task) skipping two sensitive targets.

.EXAMPLE
    .\Windows-Preflight-Cleaner.ps1 -CreateRestorePoint -ResetBase
    Isolated run with a restore point and a permanent WinSxS purge (confirmation required).

.EXAMPLE
    .\Windows-Preflight-Cleaner.ps1 -RetainReportsDays 30
    Standard run, keeps only 30 days of reports instead of 60.

.NOTES
    Author  : Nephren
    Version : 5.3.0
    To be signed via Manage-ScriptSignatures.ps1 before production use.

.NOTES
    Exit codes (useful for monitoring via Scheduled Task):
      0 = complete run, nothing to report
      1 = complete run but with locked/protected targets, or SelfTest failed
      2 = unhandled fatal error
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
$ScriptVersion = "5.3.0"

# Global safety net: any terminating error not caught locally (i.e. not
# handled by the existing try/catch blocks) bubbles up here instead of
# crashing silently with an ambiguous exit code. Lets a Scheduled Task /
# multi-machine monitoring setup tell apart a genuine failure (code 2) from
# a normal run (code 0) or a run with locked targets (code 1).
trap {
    Write-Host ""
    Write-Host "====================================================" -ForegroundColor Red
    Write-Host "  FATAL ERROR: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "====================================================" -ForegroundColor Red
    if (-not $Silent) { Read-Host "  Press ENTER to close" | Out-Null }
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
#  UTILITY FUNCTIONS
# ============================================================================
function He {
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return "" }
    return [System.Net.WebUtility]::HtmlEncode($Text)
}

function Format-Size {
    param([int64]$Bytes)
    if ($Bytes -ge 1GB) { return "{0:N2} GB" -f [double]($Bytes / 1GB) }
    elseif ($Bytes -ge 1MB) { return "{0:N2} MB" -f [double]($Bytes / 1MB) }
    elseif ($Bytes -ge 1KB) { return "{0:N2} KB" -f [double]($Bytes / 1KB) }
    else { return "$Bytes bytes" }
}

# Formats a value in GB, always with an invariant-culture period decimal
# separator (never the current machine's locale), so the console and HTML
# report display consistently in English whether the script runs on a
# French-language or English-language Windows install. Not used for values
# written to JSON/CSV: those must remain raw numbers.
function Format-GB {
    param([double]$Value)
    return $Value.ToString("N2", [System.Globalization.CultureInfo]::InvariantCulture)
}

# Percentage with an invariant-culture period decimal, for display text only
# (never inside a CSS/SVG attribute).
function Format-Pct {
    param([double]$Value)
    return $Value.ToString("N1", [System.Globalization.CultureInfo]::InvariantCulture)
}

# Invariant-culture formatting (decimal point), mandatory for any value
# inserted into a CSS attribute (e.g. width:12.3%) or SVG: a locale-dependent
# format with a comma would break the rendering there (same bug class as the
# v5.0 sparkline).
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

# Category header shown in the console to visually break up the 46 cleanup
# targets (purely cosmetic grouping, no impact on the HTML/CSV/JSON reports,
# which stay based on $Results).
function Write-Category {
    param([string]$Title)
    Write-Host ""
    Write-Host "  $Title" -ForegroundColor DarkCyan
}

# Composes a target line as a single aligned print: gray [n/46] prefix,
# colored status icon, target name aligned on a fixed column, then a dimmed
# detail (or nothing if not relevant). Replaces the old two-line format
# (Before/After/Gain/Duration measurement + status line) which produced a
# visual mismatch between the figures line and the one qualifying it.
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
        # Name too long for the column (e.g. LibreWolf profiles with a
        # suffix): the detail moves to the next line, indented to stay
        # readable rather than breaking the alignment of the other lines.
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

# Variant of Write-TargetLine for actions outside the 46-target loop (DNS,
# recycle bin, DISM, restore point): same icon+column rendering, but without
# the [n/46] counter. The 8-space prefix reproduces the width of "[ 1/46] "
# to keep the columns aligned between the two line styles.
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
        Target           = $Name
        BeforeBytes      = $Before
        AfterBytes       = $After
        GainBytes        = $gain
        BeforeFormatted  = Format-Size $Before
        AfterFormatted   = Format-Size $After
        GainFormatted    = Format-Size $gain
        ItemsRemoved     = $Count
        ItemsRemaining   = $Remaining
        DurationMs       = $ElapsedMs
    })
}

# Fast folder removal via robocopy /MIR (mirrors an empty folder onto the
# target). Much faster than Remove-Item -Recurse on folders containing a
# large number of small files (browser caches, npm...). The before/after
# count stays independent of robocopy's output language (no localized text
# parsing is ever involved, unlike robocopy's console output text).
# Safety guard: refuses any cleanup target located less than 2 levels below
# a drive root (C:\, C:\Windows, C:\Users...). All of the script's
# legitimate targets (Prefetch, SoftwareDistribution\Download, browser
# caches...) are 2 levels deep or more. This guard protects against a future
# path-entry mistake that would pass an entire system folder into
# Remove-DirectoryFast (robocopy /MIR is inherently destructive).
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

    # Remaining > 0 while before > 0 signals a lock (files currently in use)
    # rather than an already-empty folder: that distinction is made by the
    # caller (Clear-Target), not here, to keep this a low-level function.
    return [pscustomobject]@{
        Removed   = [math]::Max(0, $before - $after)
        Remaining = $after
    }
}

# Cleans a target (folder OR single file), handles -DryRun, -SkipTargets, -OnlyTargets.
function Clear-Target {
    param([string]$Name, [string]$Path)

    $script:StepCounter++
    $prefix = "[{0,2}/{1}] " -f $script:StepCounter, $script:TotalSteps

    if (-not (Test-SafeCleanupPath -Path $Path)) {
        Write-TargetLine -Prefix $prefix -Name $Name -Icon "!" -IconColor "Red" -Detail "SAFETY: path refused (too close to the drive root)" -DetailColor "Red"
        $null = $Actions.Add("$Name : SAFETY - path refused ($Path)")
        return
    }
    if ($SkipTargets -and ($SkipTargets -contains $Name)) {
        $null = $script:SkipTargetsMatched.Add($Name)
        Write-TargetLine -Prefix $prefix -Name $Name -Icon "»" -IconColor "DarkGray" -Detail "skipped (-SkipTargets)"
        return
    }
    if ($OnlyTargets -and ($OnlyTargets -notcontains $Name)) {
        Write-TargetLine -Prefix $prefix -Name $Name -Icon "»" -IconColor "DarkGray" -Detail "skipped (outside -OnlyTargets)"
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
        Write-TargetLine -Prefix $prefix -Name $Name -Icon "≈" -IconColor "Yellow" -Detail "simulation: $(Format-Size $before) would be freed" -DetailColor "Yellow"
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
        # Total lock: the folder/file had content, the removal attempt
        # removed nothing at all. Distinct from "nothing to clean" (which
        # means the target was already empty before attempting anything).
        $null = $Actions.Add("$Name : locked ($remaining item(s) not removed)")
        Write-TargetLine -Prefix $prefix -Name $Name -Icon "!" -IconColor "Red" -Detail "not removed - locked or protected ($remaining item(s))" -DetailColor "Red"
    } elseif ($remaining -gt 0 -and $count -gt 0) {
        # Partial lock: part was removed, the rest is blocked (files held
        # open by a process at cleanup time).
        $line = "{0} removed, {1} locked/protected   {2} -> {3}  (gain {4}, {5} ms)" -f $count, $remaining, (Format-Size $before), (Format-Size $after), (Format-Size $gain), $sw.ElapsedMilliseconds
        $null = $Actions.Add("$Name : partial cleanup ($count removed, $remaining locked)")
        Write-TargetLine -Prefix $prefix -Name $Name -Icon "~" -IconColor "Yellow" -Detail $line -DetailColor "Yellow"
    } elseif ($count -gt 0 -or $gain -gt 0) {
        $detailTxt = "$count item(s)"
        $null = $Actions.Add("$Name cleaned ($detailTxt)")
        $line = "{0}   {1} -> {2}  (gain {3}, {4} ms)" -f $detailTxt, (Format-Size $before), (Format-Size $after), (Format-Size $gain), $sw.ElapsedMilliseconds
        Write-TargetLine -Prefix $prefix -Name $Name -Icon "✓" -IconColor "Green" -Detail $line -DetailColor "Gray"
    } else {
        $null = $Actions.Add("$Name : nothing to clean")
        Write-TargetLine -Prefix $prefix -Name $Name -Icon "-" -IconColor "DarkGray" -Detail "nothing to clean"
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
    Write-Host "  SelfTest - Windows-Preflight-Cleaner v$ScriptVersion" -ForegroundColor Cyan
    Write-Host "====================================================" -ForegroundColor Cyan
    Write-Host ""

    $checks = New-Object System.Collections.ArrayList

    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    $null = $checks.Add([pscustomobject]@{ Test = "Administrator rights";                 Resultat = $isAdmin;                                                                                Warn = $false })
    $null = $checks.Add([pscustomobject]@{ Test = "robocopy.exe available";               Resultat = [bool](Get-Command robocopy.exe -ErrorAction SilentlyContinue);                        Warn = $false })
    $null = $checks.Add([pscustomobject]@{ Test = "DISM.exe available";                   Resultat = [bool](Get-Command DISM.exe -ErrorAction SilentlyContinue);                            Warn = $false })
    $null = $checks.Add([pscustomobject]@{ Test = "wuauserv service present";             Resultat = [bool](Get-Service wuauserv -ErrorAction SilentlyContinue);                            Warn = $false })
    $null = $checks.Add([pscustomobject]@{ Test = "FontCache service present";            Resultat = [bool](Get-Service FontCache -ErrorAction SilentlyContinue);                          Warn = $false })

    # Checkpoint-Computer is a WinPS 5.1 cmdlet, not cold-loaded in PS7.
    # An import via the compatibility layer is attempted before Get-Command.
    # If still not found after import: WARN (not FAIL) since this only affects -CreateRestorePoint.
    $checkpointAvail = [bool](Get-Command Checkpoint-Computer -ErrorAction SilentlyContinue)
    if (-not $checkpointAvail) {
        try {
            Import-Module Microsoft.PowerShell.Management -UseWindowsPowerShell -ErrorAction Stop
            $checkpointAvail = [bool](Get-Command Checkpoint-Computer -ErrorAction SilentlyContinue)
        } catch {}
    }
    $null = $checks.Add([pscustomobject]@{ Test = "Checkpoint-Computer cmdlet (optional)"; Resultat = $checkpointAvail; Warn = $true })

    $reportWritable = $false
    try {
        if (-not (Test-Path $script:ReportFolder)) { New-Item -ItemType Directory -Path $script:ReportFolder -Force | Out-Null }
        $testFile = Join-Path $script:ReportFolder ("selftest_" + [guid]::NewGuid().ToString('N') + ".tmp")
        "test" | Out-File -LiteralPath $testFile -ErrorAction Stop
        Remove-Item -LiteralPath $testFile -Force -ErrorAction SilentlyContinue
        $reportWritable = $true
    } catch {}
    $null = $checks.Add([pscustomobject]@{ Test = "Reports folder writable"; Resultat = $reportWritable; Warn = $false })

    # ------------------------------------------------------------------
    # Unit tests for internal functions (beyond the system prerequisites)
    # ------------------------------------------------------------------
    $selfTestTemp = Join-Path $env:TEMP ("PreflightCleanerSelfTest_" + [guid]::NewGuid().ToString('N'))

    # Format-Size() : bytes / KB / MB boundaries
    $fmtOk = $true
    try {
        if ((Format-Size 0) -ne "0 bytes") { $fmtOk = $false }
        if ((Format-Size 512) -notmatch "512") { $fmtOk = $false }
        if ((Format-Size 1024) -notmatch "1.00 KB") { $fmtOk = $false }
        if ((Format-Size 1048576) -notmatch "1.00 MB") { $fmtOk = $false }
    } catch { $fmtOk = $false }
    $null = $checks.Add([pscustomobject]@{ Test = "Format-Size() - bytes/KB/MB boundaries"; Resultat = $fmtOk; Warn = $false })

    # Format-GB() : simple conversion
    $fmtGoOk = $true
    try {
        if ((Format-GB 1.5) -notmatch "1.5") { $fmtGoOk = $false }
    } catch { $fmtGoOk = $false }
    $null = $checks.Add([pscustomobject]@{ Test = "Format-GB() - conversion"; Resultat = $fmtGoOk; Warn = $false })

    # Test-SafeCleanupPath() : the safety guard must refuse roots and only
    # accept paths 2+ levels below the drive root.
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
    $null = $checks.Add([pscustomobject]@{ Test = "Test-SafeCleanupPath() - root guard"; Resultat = $guardOk; Warn = $false })

    # Get-FolderSizeBytes() : byte sum on a known test folder
    $folderSizeOk = $true
    try {
        New-Item -ItemType Directory -Path $selfTestTemp -Force | Out-Null
        "0123456789" | Out-File -LiteralPath (Join-Path $selfTestTemp "a.txt") -NoNewline -Encoding ascii
        "01234" | Out-File -LiteralPath (Join-Path $selfTestTemp "b.txt") -NoNewline -Encoding ascii
        $sz = Get-FolderSizeBytes $selfTestTemp
        if ($sz -ne 15) { $folderSizeOk = $false }
    } catch { $folderSizeOk = $false }
    $null = $checks.Add([pscustomobject]@{ Test = "Get-FolderSizeBytes() - sum on test folder"; Resultat = $folderSizeOk; Warn = $false })

    # Remove-DirectoryFast() : full removal of an unlocked folder
    $removeFullOk = $true
    try {
        $rd = Remove-DirectoryFast -Path $selfTestTemp
        if ($rd.Removed -ne 2 -or $rd.Remaining -ne 0) { $removeFullOk = $false }
        if (Test-Path (Join-Path $selfTestTemp "a.txt")) { $removeFullOk = $false }
    } catch { $removeFullOk = $false }
    $null = $checks.Add([pscustomobject]@{ Test = "Remove-DirectoryFast() - full removal"; Resultat = $removeFullOk; Warn = $false })

    # Remove-DirectoryFast() : detection of a locked file (core of the v5.2
    # fix distinguishing "nothing to clean" vs "locked"). An exclusive
    # FileStream is opened on a file to simulate an application holding it open.
    $lockDetectOk = $true
    $lockedFileStream = $null
    try {
        New-Item -ItemType Directory -Path $selfTestTemp -Force | Out-Null
        $lockedFile = Join-Path $selfTestTemp "locked.txt"
        "locked" | Out-File -LiteralPath $lockedFile -NoNewline -Encoding ascii
        $lockedFileStream = [System.IO.File]::Open($lockedFile, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::None)
        $rd2 = Remove-DirectoryFast -Path $selfTestTemp
        if ($rd2.Removed -ne 0 -or $rd2.Remaining -ne 1) { $lockDetectOk = $false }
    } catch { $lockDetectOk = $false }
    finally {
        if ($lockedFileStream) { $lockedFileStream.Dispose() }
        try { Remove-Item -LiteralPath $selfTestTemp -Recurse -Force -ErrorAction SilentlyContinue } catch {}
    }
    $null = $checks.Add([pscustomobject]@{ Test = "Remove-DirectoryFast() - lock detection"; Resultat = $lockDetectOk; Warn = $false })

    # Baseline JSON round-trip (write then re-read, same mechanism as a real run)
    $jsonRoundTripOk = $true
    try {
        $tmpBaseline = Join-Path $env:TEMP ("selftest_baseline_" + [guid]::NewGuid().ToString('N') + ".json")
        @{ Test = "value"; Number = 42 } | ConvertTo-Json | Out-File -LiteralPath $tmpBaseline -Encoding utf8 -Force
        $reread = Get-Content -LiteralPath $tmpBaseline -Raw | ConvertFrom-Json
        if ($reread.Number -ne 42) { $jsonRoundTripOk = $false }
        Remove-Item -LiteralPath $tmpBaseline -Force -ErrorAction SilentlyContinue
    } catch { $jsonRoundTripOk = $false }
    $null = $checks.Add([pscustomobject]@{ Test = "Baseline JSON round-trip"; Resultat = $jsonRoundTripOk; Warn = $false })

    # History CSV round-trip (';' delimiter, same convention as a real run)
    $csvRoundTripOk = $true
    try {
        $tmpCsv = Join-Path $env:TEMP ("selftest_history_" + [guid]::NewGuid().ToString('N') + ".csv")
        [pscustomobject]@{ Target = "Test"; Gain = 123 } | Export-Csv -LiteralPath $tmpCsv -NoTypeInformation -Delimiter ';' -Encoding UTF8
        $rereadCsv = Import-Csv -LiteralPath $tmpCsv -Delimiter ';'
        if ($rereadCsv.Gain -ne "123") { $csvRoundTripOk = $false }
        Remove-Item -LiteralPath $tmpCsv -Force -ErrorAction SilentlyContinue
    } catch { $csvRoundTripOk = $false }
    $null = $checks.Add([pscustomobject]@{ Test = "History CSV round-trip"; Resultat = $csvRoundTripOk; Warn = $false })

    # LibreWolf detection: must never throw, even if the profiles folder is
    # absent (user without LibreWolf installed).
    $librewolfDetectOk = $true
    try {
        $lwRoot = Join-Path $env:APPDATA "LibreWolf\Profiles"
        $null = @(Get-ChildItem -Path $lwRoot -Directory -ErrorAction SilentlyContinue)
    } catch { $librewolfDetectOk = $false }
    $null = $checks.Add([pscustomobject]@{ Test = "LibreWolf profile detection (no exception)"; Resultat = $librewolfDetectOk; Warn = $false })

    # Steam detection via registry: must never throw, even if the
    # HKCU:\Software\Valve\Steam key is absent (Steam not installed).
    $steamDetectOk = $true
    try {
        $null = Get-ItemProperty -Path "HKCU:\Software\Valve\Steam" -ErrorAction SilentlyContinue
    } catch { $steamDetectOk = $false }
    $null = $checks.Add([pscustomobject]@{ Test = "Steam detection via registry (no exception)"; Resultat = $steamDetectOk; Warn = $false })


    foreach ($c in $checks) {
        if ($c.Resultat) {
            Write-Step ("  {0,-49} : PASS" -f $c.Test) "OK"
        } elseif ($c.Warn) {
            Write-Step ("  {0,-49} : WARN (optional)" -f $c.Test) "WARN"
        } else {
            Write-Step ("  {0,-49} : FAIL" -f $c.Test) "ERROR"
        }
    }

    $failCount = @($checks | Where-Object { -not $_.Resultat -and -not $_.Warn }).Count
    $warnCount = @($checks | Where-Object { -not $_.Resultat -and $_.Warn }).Count
    $script:SelfTestFailCount = $failCount
    Write-Host ""
    if ($failCount -eq 0 -and $warnCount -eq 0) {
        Write-Host "  All tests passed." -ForegroundColor Green
    } elseif ($failCount -eq 0) {
        Write-Host "  $warnCount optional warning(s) - no blocking issue." -ForegroundColor Yellow
    } else {
        Write-Host "  $failCount test(s) failed, $warnCount warning(s)." -ForegroundColor Red
    }
    Write-Host ""
}

# ============================================================================
#  INITIALIZATION
# ============================================================================
$StartTime  = Get-Date
$TimeStamp  = $StartTime.ToString("yyyy-MM-dd_HH-mm-ss")
$ReportFolder = "$env:USERPROFILE\Desktop\Maintenance_Reports\Windows-Preflight-Cleaner"
if (-not (Test-Path $ReportFolder)) { New-Item -ItemType Directory -Path $ReportFolder -Force | Out-Null }

$HtmlFile     = Join-Path $ReportFolder "Windows-Preflight-Cleaner-$TimeStamp.html"
$JsonFile     = Join-Path $ReportFolder "Windows-Preflight-Cleaner-$TimeStamp.json"
$HistoryFile  = Join-Path $ReportFolder "Windows-Preflight-Cleaner-History.csv"
$BaselineFile = Join-Path $ReportFolder "Windows-Preflight-Cleaner-Baseline.json"
$TranscriptFile = Join-Path $ReportFolder "Transcript-$TimeStamp.log"

if ($SelfTest) {
    Invoke-SelfTest
    if (-not $Silent) { Read-Host "  Press ENTER to close" | Out-Null }
    $selfTestExitCode = 0
    if ($script:SelfTestFailCount -gt 0) { $selfTestExitCode = 1 }
    exit $selfTestExitCode
}

try { Start-Transcript -Path $TranscriptFile -ErrorAction SilentlyContinue | Out-Null } catch {}

$Results = New-Object System.Collections.ArrayList
$Actions = New-Object System.Collections.ArrayList
$script:StepCounter      = 0
$script:TotalFilesRemoved = 0
# Tracks the -OnlyTargets/-SkipTargets names actually encountered during the
# run, to detect at the end of the pass a typo that would make a supplied
# name match no real target (see the guard block in Clear-Target and the
# check at the end of the script).
$script:OnlyTargetsMatched = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
$script:SkipTargetsMatched = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)

Write-Host ""
Write-Host "====================================================" -ForegroundColor Magenta
Write-Host "   Windows-Preflight-Cleaner v$ScriptVersion$(if($DryRun){' [DRY RUN MODE]'})" -ForegroundColor Magenta
Write-Host "====================================================" -ForegroundColor Magenta
Write-Host ""

# Previous baseline (for the delta calculation)
$PreviousBaseline = $null
if (Test-Path $BaselineFile) {
    try { $PreviousBaseline = Get-Content -LiteralPath $BaselineFile -Raw | ConvertFrom-Json } catch {}
}

# Previous history (for the trend sparkline)
$PreviousHistoryRows = @()
if (Test-Path $HistoryFile) {
    try { $PreviousHistoryRows = Import-Csv -LiteralPath $HistoryFile -Delimiter ';' } catch {}
}

# ============================================================================
#  DYNAMIC TARGET DETECTION
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
#  INITIAL DISK STATE
# ============================================================================
$DriveC = Get-PSDrive C
[int64]$FreeBeforeBytes = $DriveC.Free
$FreeBeforeGB = [math]::Round($FreeBeforeBytes / 1GB, 2)
Write-Step "Free space before cleanup: $(Format-GB $FreeBeforeGB) GB" "INFO"
Write-Host ""
Write-Host "  " -NoNewline
Write-Host "✓" -NoNewline -ForegroundColor Green
Write-Host " cleaned   " -NoNewline -ForegroundColor DarkGray
Write-Host "~" -NoNewline -ForegroundColor Yellow
Write-Host " partial   " -NoNewline -ForegroundColor DarkGray
Write-Host "!" -NoNewline -ForegroundColor Red
Write-Host " locked/protected   " -NoNewline -ForegroundColor DarkGray
Write-Host "-" -NoNewline -ForegroundColor DarkGray
Write-Host " empty   " -NoNewline -ForegroundColor DarkGray
Write-Host "·" -NoNewline -ForegroundColor DarkGray
Write-Host " absent   " -NoNewline -ForegroundColor DarkGray
Write-Host "»" -NoNewline -ForegroundColor DarkGray
Write-Host " skipped" -ForegroundColor DarkGray
Write-Host ""

# ============================================================================
#  CLEANUP - WINDOWS UPDATE (stop/restart service)
# ============================================================================
Write-Category "Windows Update"
try {
    if (-not $DryRun) { Stop-Service wuauserv -Force -ErrorAction SilentlyContinue }
    Clear-Target "Windows Update" "C:\Windows\SoftwareDistribution\Download"
} finally {
    if (-not $DryRun) { Start-Service wuauserv -ErrorAction SilentlyContinue }
}

# ============================================================================
#  CLEANUP - TEMP FILES & SYSTEM CACHES
# ============================================================================
Write-Category "Temp files and system caches"
Clear-Target "User Temp"               $env:TEMP
Clear-Target "Windows Temp"            "C:\Windows\Temp"
Clear-Target "DirectX Cache"           (Join-Path $env:LOCALAPPDATA "D3DSCache")
Clear-Target "Delivery Optimization"   "C:\Windows\SoftwareDistribution\DeliveryOptimization"
Clear-Target "Explorer Thumbnails"     (Join-Path $env:LOCALAPPDATA "Microsoft\Windows\Explorer")
Clear-Target "WER ReportArchive"       "C:\ProgramData\Microsoft\Windows\WER\ReportArchive"
Clear-Target "WER ReportQueue"         "C:\ProgramData\Microsoft\Windows\WER\ReportQueue"
Clear-Target "WER Temp"                (Join-Path $env:LOCALAPPDATA "Microsoft\Windows\WER\Temp")
Clear-Target "CrashDumps"              (Join-Path $env:LOCALAPPDATA "CrashDumps")

# ============================================================================
#  CLEANUP - LOGS (new in v5)
# ============================================================================
Write-Category "Logs"
Clear-Target "WindowsUpdate Logs"  "C:\Windows\Logs\WindowsUpdate"
Clear-Target "CBS Logs"            "C:\Windows\Logs\CBS"
Clear-Target "DISM Logs"           "C:\Windows\Logs\DISM"
Clear-Target "Panther Setup Logs"  "C:\Windows\Panther"

# ============================================================================
#  CLEANUP - PREFETCH / MEMORY DUMPS (new in v5)
# ============================================================================
Write-Category "Prefetch and memory dumps"
Clear-Target "Prefetch"                "C:\Windows\Prefetch"
Clear-Target "Memory Dumps (Minidump)" "C:\Windows\Minidump"
Clear-Target "MEMORY.DMP"              "C:\Windows\MEMORY.DMP"

# ============================================================================
#  CLEANUP - SINGLE-FILE SYSTEM CACHES (new in v5, services stopped for the delete)
# ============================================================================
Write-Category "Single-file system caches"
Clear-Target "IconCache.db" (Join-Path $env:LOCALAPPDATA "IconCache.db")

try {
    if (-not $DryRun) { Stop-Service FontCache -Force -ErrorAction SilentlyContinue }
    Clear-Target "FNTCACHE.DAT" "C:\Windows\System32\FNTCACHE.DAT"
} finally {
    if (-not $DryRun) { Start-Service FontCache -ErrorAction SilentlyContinue }
}

# ============================================================================
#  CLEANUP - DEV TOOLS (new in v5)
# ============================================================================
Write-Category "Development tools"
Clear-Target "npm Cache"   (Join-Path $env:APPDATA "npm-cache")
Clear-Target "pip Cache"   (Join-Path $env:LOCALAPPDATA "pip\Cache")
Clear-Target "cargo Cache" (Join-Path $env:USERPROFILE ".cargo\registry\cache")
Clear-Target "VS Code Cache"       (Join-Path $env:APPDATA "Code\Cache")
Clear-Target "VS Code CachedData"  (Join-Path $env:APPDATA "Code\CachedData")
Clear-Target "VS Code Logs"        (Join-Path $env:APPDATA "Code\logs")
Clear-Target "VS Code GPUCache"    (Join-Path $env:APPDATA "Code\GPUCache")

# ============================================================================
#  CLEANUP - WEBVIEW2 (new in v5.1)
#  Chromium component independent of Edge (always present even if Edge is
#  uninstalled), used by Widgets, Teams, and various apps for embedded web
#  rendering. Cache only: regenerates automatically, no risk.
# ============================================================================
Write-Category "WebView2"
Clear-Target "WebView2 Cache"      (Join-Path $env:LOCALAPPDATA "Microsoft\EdgeWebView\User Data\Default\Cache")
Clear-Target "WebView2 Code Cache" (Join-Path $env:LOCALAPPDATA "Microsoft\EdgeWebView\User Data\Default\Code Cache")
Clear-Target "WebView2 GPUCache"   (Join-Path $env:LOCALAPPDATA "Microsoft\EdgeWebView\User Data\Default\GPUCache")

# ============================================================================
#  CLEANUP - RECENT ACCESS HISTORY (new in v5.1)
#  JumpLists (Start menu/taskbar) and Explorer MRU. Purely cosmetic/privacy,
#  no functional impact: rebuilt automatically with use.
# ============================================================================
Write-Category "Recent access history"
Clear-Target "Automatic JumpLists" (Join-Path $env:APPDATA "Microsoft\Windows\Recent\AutomaticDestinations")
Clear-Target "Custom JumpLists"    (Join-Path $env:APPDATA "Microsoft\Windows\Recent\CustomDestinations")

# ============================================================================
#  CLEANUP - NVIDIA (new in v5)
# ============================================================================
Write-Category "NVIDIA"
Clear-Target "NVIDIA DXCache"    (Join-Path $env:LOCALAPPDATA "NVIDIA\DXCache")
Clear-Target "NVIDIA GLCache"    (Join-Path $env:LOCALAPPDATA "NVIDIA\GLCache")
Clear-Target "NVIDIA OptixCache" (Join-Path $env:LOCALAPPDATA "NVIDIA\OptixCache")

# ============================================================================
#  CLEANUP - SPOTIFY (new in v5)
# ============================================================================
Write-Category "Spotify"
Clear-Target "Spotify Storage Cache" (Join-Path $env:LOCALAPPDATA "Spotify\Storage")
Clear-Target "Spotify Data Cache"    (Join-Path $env:LOCALAPPDATA "Spotify\Data")

# ============================================================================
#  CLEANUP - STEAM (new in v5, conditional on registry detection)
# ============================================================================
Write-Category "Steam"
if ($SteamPath) {
    Clear-Target "Steam AppCache"          (Join-Path $SteamPath "appcache")
    Clear-Target "Steam HtmlCache"         (Join-Path $SteamPath "htmlcache")
    Clear-Target "Steam Incomplete Downloads" (Join-Path $SteamPath "steamapps\downloading")
} else {
    Write-Step "Steam: not detected via the registry, targets skipped" "WARN"
}

# ============================================================================
#  CLEANUP - BROWSERS
# ============================================================================
Write-Category "Browsers"
Clear-Target "Brave Cache"      (Join-Path $env:LOCALAPPDATA "BraveSoftware\Brave-Browser\User Data\Default\Cache")
Clear-Target "Brave Code Cache" (Join-Path $env:LOCALAPPDATA "BraveSoftware\Brave-Browser\User Data\Default\Code Cache")
Clear-Target "Brave GPU Cache"  (Join-Path $env:LOCALAPPDATA "BraveSoftware\Brave-Browser\User Data\Default\GPUCache")

foreach ($profile in $LibreWolfProfiles) {
    Clear-Target "LibreWolf Cache [$($profile.Name)]"        (Join-Path $profile.FullName "cache2")
    Clear-Target "LibreWolf StartupCache [$($profile.Name)]" (Join-Path $profile.FullName "startupCache")
}

# ============================================================================
#  CLEANUP - MULTI-USER TEMP PROFILES (new in v5)
# ============================================================================
if ($OtherUserTempTargets -and $OtherUserTempTargets.Count -gt 0) {
    Write-Category "Multi-user temp profiles"
    foreach ($t in $OtherUserTempTargets) {
        Clear-Target "Temp [$($t.Owner)]" $t.Path
    }
}

# ============================================================================
#  DNS & RECYCLE BIN
# ============================================================================
Write-Category "DNS and recycle bin"
if ($DryRun) {
    Write-ActionLine -Name "DNS Cache" -Icon "≈" -IconColor "Yellow" -Detail "simulation: skipped" -DetailColor "Yellow"
    Write-ActionLine -Name "Recycle Bin" -Icon "≈" -IconColor "Yellow" -Detail "simulation: skipped" -DetailColor "Yellow"
} else {
    try {
        & ipconfig.exe /flushdns *> $null
        if ($LASTEXITCODE -eq 0) {
            Write-ActionLine -Name "DNS Cache" -Icon "✓" -IconColor "Green" -Detail "flushed" -DetailColor "Gray"
            $null = $Actions.Add("DNS Cache flushed")
        } else {
            Write-ActionLine -Name "DNS Cache" -Icon "~" -IconColor "Yellow" -Detail "exit code $LASTEXITCODE" -DetailColor "Yellow"
        }
    } catch {
        Write-ActionLine -Name "DNS Cache" -Icon "!" -IconColor "Red" -Detail "flush failed" -DetailColor "Red"
    }

    try {
        Clear-RecycleBin -Force -ErrorAction SilentlyContinue
        Write-ActionLine -Name "Recycle Bin" -Icon "✓" -IconColor "Green" -Detail "emptied" -DetailColor "Gray"
        $null = $Actions.Add("Recycle Bin emptied")
    } catch {
        Write-ActionLine -Name "Recycle Bin" -Icon "!" -IconColor "Red" -Detail "empty failed" -DetailColor "Red"
    }
}

# ============================================================================
#  SYSTEM RESTORE POINT (optional, new in v5)
# ============================================================================
if ($CreateRestorePoint) {
    Write-Category "System restore point"
    if ($DryRun) {
        Write-ActionLine -Name "Restore Point" -Icon "≈" -IconColor "Yellow" -Detail "simulation: skipped" -DetailColor "Yellow"
    } else {
        Write-Step "Creating a system restore point..."
        try {
            Enable-ComputerRestore -Drive "C:\" -ErrorAction SilentlyContinue
            Checkpoint-Computer -Description "Before Windows-Preflight-Cleaner v5 ($TimeStamp)" -RestorePointType "MODIFY_SETTINGS" -ErrorAction Stop
            Write-ActionLine -Name "Restore Point" -Icon "✓" -IconColor "Green" -Detail "created" -DetailColor "Gray"
            $null = $Actions.Add("System restore point created")
        } catch {
            Write-ActionLine -Name "Restore Point" -Icon "~" -IconColor "Yellow" -Detail "failed or Windows throttle (1 max/24h) - $($_.Exception.Message)" -DetailColor "Yellow"
        }
    }
}

# ============================================================================
#  DISM - COMPONENT CLEANUP (with optional ResetBase)
# ============================================================================
Write-Category "DISM - component cleanup"
if ($DryRun) {
    Write-ActionLine -Name "DISM StartComponentCleanup" -Icon "≈" -IconColor "Yellow" -Detail "simulation: not run" -DetailColor "Yellow"
} else {
    if ($ResetBase -and -not $Silent) {
        Write-Host ""
        Write-Host "  WARNING: -ResetBase PERMANENTLY removes old versions of" -ForegroundColor Red
        Write-Host "  Windows components (WinSxS). No update rollback will be" -ForegroundColor Red
        Write-Host "  possible after this operation." -ForegroundColor Red
        $confirmReset = Read-Host "  Confirm ResetBase? [y/N]"
        if ($confirmReset -notmatch '^[Yy]') {
            Write-ActionLine -Name "ResetBase" -Icon "~" -IconColor "Yellow" -Detail "cancelled by the user, standard StartComponentCleanup kept" -DetailColor "Yellow"
            $ResetBase = $false
        }
    }

    Write-Step "DISM StartComponentCleanup$(if($ResetBase){' /ResetBase'}) running (can take several minutes)..."
    try {
        $dismArgs = @('/Online', '/Cleanup-Image', '/StartComponentCleanup')
        if ($ResetBase) { $dismArgs += '/ResetBase' }
        & DISM.exe @dismArgs *> $null
        Write-ActionLine -Name "DISM StartComponentCleanup" -Icon "✓" -IconColor "Green" -Detail "completed" -DetailColor "Gray"
        $null = $Actions.Add("DISM StartComponentCleanup$(if($ResetBase){' /ResetBase'}) executed")
    } catch {
        Write-ActionLine -Name "DISM StartComponentCleanup" -Icon "!" -IconColor "Red" -Detail "failed - $($_.Exception.Message)" -DetailColor "Red"
    }
}

# ============================================================================
#  FINAL CALCULATIONS
# ============================================================================
Write-Host ""
$DriveC = Get-PSDrive C
[int64]$FreeAfterBytes = $DriveC.Free
$FreeAfterGB = [math]::Round($FreeAfterBytes / 1GB, 2)
$DiskGainGB  = [math]::Round([math]::Max(0L, $FreeAfterBytes - $FreeBeforeBytes) / 1GB, 2)

$RecoveredMeasure = $Results | Measure-Object -Property GainBytes -Sum
[int64]$RecoveredBytes = if ($RecoveredMeasure -and $null -ne $RecoveredMeasure.Sum) { $RecoveredMeasure.Sum } else { 0L }
$RecoveredGB = [math]::Round($RecoveredBytes / 1GB, 2)

$EndTime  = Get-Date
$Duration = "{0:mm} min {0:ss} s" -f ($EndTime - $StartTime)

Write-Step "Free space after cleanup: $(Format-GB $FreeAfterGB) GB (disk gain: $(Format-GB $DiskGainGB) GB)" "OK"
Write-Step "Total volume identified as cleanable: $(Format-GB $RecoveredGB) GB" "OK"
Write-Step "Items removed: $($script:TotalFilesRemoved)" "OK"
$LockedTargets = @($Results | Where-Object { $_.ItemsRemaining -gt 0 })
if ($LockedTargets.Count -gt 0) {
    $lockedNames = ($LockedTargets | Select-Object -ExpandProperty Target) -join ", "
    # AfterBytes for a locked target corresponds exactly to what could not be
    # removed (robocopy /MIR would have removed everything otherwise): this
    # is therefore a reliable measurement, not an estimate, of the space
    # blocked by the lock/protection.
    $lockedMeasure = $LockedTargets | Measure-Object -Property AfterBytes -Sum
    $lockedBytes = if ($lockedMeasure -and $null -ne $lockedMeasure.Sum) { $lockedMeasure.Sum } else { 0L }
    Write-Step "Targets with items not removed (locked/protected): $($LockedTargets.Count) -> $lockedNames ($(Format-Size $lockedBytes) not reclaimed)" "WARN"
}

# Typo detection in -OnlyTargets/-SkipTargets: if a name supplied by the
# user matched no real target during the whole run, that's most likely a
# typing mistake that silently made the filter a no-op for that name
# (without raising a PowerShell error, since -contains does not validate
# that the target exists).
if ($OnlyTargets) {
    $unmatchedOnly = @($OnlyTargets | Where-Object { -not $script:OnlyTargetsMatched.Contains($_) })
    if ($unmatchedOnly.Count -gt 0) {
        Write-Step "WARNING -OnlyTargets: no target matches '$($unmatchedOnly -join "', '")' (check spelling)" "WARN"
    }
}
if ($SkipTargets) {
    $unmatchedSkip = @($SkipTargets | Where-Object { -not $script:SkipTargetsMatched.Contains($_) })
    if ($unmatchedSkip.Count -gt 0) {
        Write-Step "WARNING -SkipTargets: no target matches '$($unmatchedSkip -join "', '")' (check spelling)" "WARN"
    }
}

Write-Step "Total duration: $Duration" "OK"
Write-Host ""

# Delta vs previous run
$DeltaText = $null
if ($PreviousBaseline -and $PreviousBaseline.FreeAfterGB) {
    $deltaVal  = [math]::Round($FreeAfterGB - [double]$PreviousBaseline.FreeAfterGB, 2)
    $deltaSign = if ($deltaVal -ge 0) { '+' } else { '' }
    $DeltaText = "Free space change since the run on $($PreviousBaseline.Date): $deltaSign$(Format-GB $deltaVal) GB"
    Write-Step $DeltaText "INFO"
}

# ============================================================================
#  BASELINE JSON EXPORT (for the next run's delta)
# ============================================================================
try {
    [pscustomobject]@{
        Date         = $StartTime.ToString("yyyy-MM-dd HH:mm:ss")
        Version      = $ScriptVersion
        DiskGainGB   = $DiskGainGB
        RecoveredGB  = $RecoveredGB
        FilesRemoved = $script:TotalFilesRemoved
        FreeAfterGB  = $FreeAfterGB
        Duration     = $Duration
    } | ConvertTo-Json | Out-File -LiteralPath $BaselineFile -Encoding utf8 -Force
} catch {}

# ============================================================================
#  TREND SPARKLINE (last 10 runs)
# ============================================================================
$TrendValues = @()
try {
    $TrendValues = ($PreviousHistoryRows | Select-Object -Last 9 | ForEach-Object { [double]$_.DiskGainGB })
} catch {}
$TrendValues += [double]$DiskGainGB
$SparklineSvg = Get-SparklineSvg -Values $TrendValues

# ============================================================================
#  HISTORY CSV EXPORT
# ============================================================================
try {
    [pscustomobject]@{
        Date              = $StartTime.ToString("yyyy-MM-dd HH:mm:ss")
        Version           = $ScriptVersion
        DiskGainGB        = $DiskGainGB
        CumulativeGainGB  = $RecoveredGB
        FilesRemoved      = $script:TotalFilesRemoved
        FreeAfterGB       = $FreeAfterGB
        Duration          = $Duration
        DryRunMode        = [bool]$DryRun
    } | Export-Csv -LiteralPath $HistoryFile -Append -NoTypeInformation -Delimiter ';' -Encoding UTF8
} catch {
    Write-Step "History CSV: write failed - $($_.Exception.Message)" "WARN"
}

# ============================================================================
#  FULL JSON EXPORT
# ============================================================================
try {
    [pscustomobject]@{
        Version           = $ScriptVersion
        Date              = $StartTime.ToString("yyyy-MM-dd HH:mm:ss")
        Machine           = $env:COMPUTERNAME
        User              = $env:USERNAME
        DryRunMode        = [bool]$DryRun
        DurationSeconds   = [math]::Round(($EndTime - $StartTime).TotalSeconds, 1)
        FreeBeforeGB      = $FreeBeforeGB
        FreeAfterGB       = $FreeAfterGB
        DiskGainGB        = $DiskGainGB
        CumulativeGainGB  = $RecoveredGB
        FilesRemoved      = $script:TotalFilesRemoved
        RestorePoint      = [bool]$CreateRestorePoint
        ResetBaseUsed     = [bool]$ResetBase
        Results           = $Results
        Actions           = $Actions
    } | ConvertTo-Json -Depth 6 | Out-File -LiteralPath $JsonFile -Encoding utf8 -Force
} catch {
    Write-Step "JSON export: write failed - $($_.Exception.Message)" "WARN"
}

# ============================================================================
#  SYSTEM INFO & TOP GAINS (for the HTML report)
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

$TopGains = @($Results | Where-Object { $_.GainBytes -gt 0 } | Sort-Object -Property GainBytes -Descending | Select-Object -First 5)

# ============================================================================
#  HTML REPORT
# ============================================================================
$RowsHtml = New-Object System.Collections.Generic.List[string]
foreach ($r in $Results) {
    # Same classification logic as Clear-Target in the console (console/HTML
    # consistency): distinguishes cleaned / partial / locked / empty /
    # simulation, instead of the sole "GainBytes=0 and ItemsRemoved=0"
    # criterion, which conflated "already empty folder" with "locked,
    # nothing could be removed".
    $remaining = if ($r.PSObject.Properties.Name -contains 'ItemsRemaining') { $r.ItemsRemaining } else { 0 }
    if ($DryRun) {
        if ($r.GainBytes -gt 0) {
            $rowClass = " class='row-partial'"
            $statusBadge = "<span class='status-badge status-sim' title='Simulation'>&#8776;</span>"
        } else {
            $rowClass = " class='row-empty'"
            $statusBadge = "<span class='status-badge status-empty' title='Empty'>-</span>"
        }
    } elseif ($remaining -gt 0 -and $r.ItemsRemoved -eq 0) {
        $rowClass = " class='row-locked'"
        $statusBadge = "<span class='status-badge status-locked' title='Locked or protected'>&#33;</span>"
    } elseif ($remaining -gt 0 -and $r.ItemsRemoved -gt 0) {
        $rowClass = " class='row-partial'"
        $statusBadge = "<span class='status-badge status-partial' title='Partially cleaned'>~</span>"
    } elseif ($r.ItemsRemoved -gt 0 -or $r.GainBytes -gt 0) {
        $rowClass = ""
        $statusBadge = "<span class='status-badge status-ok' title='Cleaned'>&#10003;</span>"
    } else {
        $rowClass = " class='row-empty'"
        $statusBadge = "<span class='status-badge status-empty' title='Empty'>-</span>"
    }
    $gainClass = if ($r.GainBytes -gt 0) { "gain-pos" } else { "gain-zero" }
    $durationTxt = if ($r.DurationMs -gt 0) { "$($r.DurationMs) ms" } else { "-" }
    $RowsHtml.Add("<tr$rowClass><td class='num'>$statusBadge</td><td>$(He $r.Target)</td><td class='num'>$(He $r.BeforeFormatted)</td><td class='num'>$(He $r.AfterFormatted)</td><td class='num $gainClass'>$(He $r.GainFormatted)</td><td class='num'>$($r.ItemsRemoved)</td><td class='num'>$(He $durationTxt)</td></tr>")
}
$ResultsTableRows = [string]::Join("`n", $RowsHtml)
if ($Results.Count -eq 0) {
    # Same fallback logic as the "Top gains" section (No significant gain)
    # for a fully empty table: happens if -OnlyTargets matches no target
    # (typo) or if -SkipTargets excludes everything, instead of an empty
    # table body with no explanation.
    $emptyReason = if ($OnlyTargets) { "no target matches -OnlyTargets (check spelling)" } elseif ($SkipTargets) { "all targets were excluded by -SkipTargets" } else { "no target processed" }
    $ResultsTableRows = "<tr><td colspan='7' style='text-align:center; color: var(--muted); padding: 20px;'>No target processed - $(He $emptyReason)</td></tr>"
}

$ActionsHtml = New-Object System.Collections.Generic.List[string]
foreach ($a in $Actions) {
    if ($a -match ' : locked ') {
        $ActionsHtml.Add("<li class='action-locked'><span class='action-icon'>&#33;</span>$(He $a)</li>")
    } elseif ($a -match 'partial cleanup') {
        $ActionsHtml.Add("<li class='action-partial'><span class='action-icon'>~</span>$(He $a)</li>")
    } elseif ($a -match ' : simulation ') {
        $ActionsHtml.Add("<li class='action-sim'><span class='action-icon'>&#8776;</span>$(He $a)</li>")
    } elseif ($a -match 'nothing to clean') {
        $ActionsHtml.Add("<li class='action-neutral'><span class='action-icon'>&#9675;</span>$(He $a)</li>")
    } else {
        $ActionsHtml.Add("<li class='action-ok'><span class='action-icon'>&#10003;</span>$(He $a)</li>")
    }
}
$ActionsListItems = [string]::Join("`n", $ActionsHtml)

$TopGainsHtml = New-Object System.Collections.Generic.List[string]
foreach ($g in $TopGains) {
    $TopGainsHtml.Add("<li><span class='top-gain-name'>$(He $g.Target)</span><span class='top-gain-size'>$(He $g.GainFormatted)</span></li>")
}
if ($TopGainsHtml.Count -eq 0) {
    $TopGainsHtml.Add("<li><span class='top-gain-name'>No significant gain on this run</span></li>")
}
$TopGainsListItems = [string]::Join("`n", $TopGainsHtml)

$DeltaBlockHtml = ""
if ($DeltaText) {
    $DeltaBlockHtml = "<div class='card-sub'>$(He $DeltaText)</div>"
}

$DryRunBadgeHtml = ""
if ($DryRun) {
    $DryRunBadgeHtml = "<span class='badge-sim'>DRY RUN MODE</span>"
}

$SparklineSectionHtml = ""
if ($SparklineSvg) {
    $SparklineSectionHtml = @"
<div class="section-title">Trend (last 10 runs)</div>
<div class="card">$SparklineSvg</div>
"@
}

$Html = @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Cleanup Report - $env:COMPUTERNAME</title>
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
      <h1>Windows 11 Cleanup Report $DryRunBadgeHtml</h1>
      <div class="sub">$env:COMPUTERNAME - $OsCaption - $TimeStamp</div>
    </div>
  </div>

  <div class="grid">
    <div class="card">
      <div class="card-label">Measured gain (drive C:)</div>
      <div class="card-value accent">$(Format-GB $DiskGainGB) GB</div>
      <div class="card-sub">Free space: $(Format-GB $FreeBeforeGB) GB &rarr; $(Format-GB $FreeAfterGB) GB</div>
      $DeltaBlockHtml
    </div>
    <div class="card">
      <div class="card-label">Cumulative gain (folders)</div>
      <div class="card-value green">$(Format-GB $RecoveredGB) GB</div>
      <div class="card-sub">Sum of per-target gains</div>
    </div>
    <div class="card">
      <div class="card-label">Items removed</div>
      <div class="card-value">$($script:TotalFilesRemoved)</div>
      <div class="card-sub">Files &amp; folders</div>
    </div>
    <div class="card">
      <div class="card-label">Duration</div>
      <div class="card-value">$Duration</div>
      <div class="card-sub">Started $($StartTime.ToString('HH:mm:ss'))</div>
    </div>

    <div class="card wide">
      <div class="card-label">Drive C: usage after cleanup</div>
      <div class="disk-bar-wrap">
        <div class="disk-bar-labels">
          <span>0</span>
          <span>$(Format-Pct $DiskUsedPercent) % used - $(Format-GB $FreeAfterGB) GB free out of $(Format-GB $DiskTotalGB) GB</span>
          <span>$(Format-GB $DiskTotalGB) GB</span>
        </div>
        <div class="disk-bar-track">
          <div class="disk-bar-used" style="width:$(Format-NumInvariant $DiskUsedPercent)%">
            <div class="disk-bar-gain" style="width:$(Format-NumInvariant $DiskGainPercent)%"></div>
          </div>
        </div>
        <div class="card-sub" style="margin-top:6px">The gradient portion represents the space reclaimed by this cleanup ($(Format-Pct $DiskGainPercent) % of the total disk)</div>
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

  <div class="section-title">System</div>
  <div class="card">
    <table>
      <tr><th>OS</th><th>CPU</th><th>RAM</th><th>Machine</th><th>User</th></tr>
      <tr>
        <td>$(He $OsCaption)</td>
        <td>$(He $CpuName)</td>
        <td class="num">$("{0:N1}" -f $RamGB) GB</td>
        <td>$(He $env:COMPUTERNAME)</td>
        <td>$(He $env:USERNAME)</td>
      </tr>
    </table>
  </div>

  <div class="section-title">Detail per target ($($Results.Count) targets processed)</div>
  <div class="status-legend">
    <span><span class="status-badge status-ok">&#10003;</span> Cleaned</span>
    <span><span class="status-badge status-partial">~</span> Partial</span>
    <span><span class="status-badge status-locked">&#33;</span> Locked/protected</span>
    <span><span class="status-badge status-empty">-</span> Empty</span>
    <span><span class="status-badge status-sim">&#8776;</span> Simulation (-DryRun)</span>
  </div>
  <div class="card">
    <input type="text" id="filterInput" onkeyup="filterTable()" placeholder="Filter by target name..." class="filter-box">
    <table id="resultsTable">
      <thead>
        <tr>
          <th></th>
          <th>Target</th>
          <th style="text-align:right">Before</th>
          <th style="text-align:right">After</th>
          <th style="text-align:right">Gain</th>
          <th style="text-align:right">Items</th>
          <th style="text-align:right">Duration</th>
        </tr>
      </thead>
      <tbody>
$ResultsTableRows
      </tbody>
    </table>
  </div>

  <div class="section-title">Action log ($($Actions.Count))</div>
  <div class="card">
    <ul class="action-list">
$ActionsListItems
    </ul>
  </div>

  <div class="footer">
    Windows-Preflight-Cleaner v$ScriptVersion - Generated on $($EndTime.ToString('yyyy-MM-dd \a\t HH:mm:ss')) -
    JSON: $(Split-Path $JsonFile -Leaf) - History: $(Split-Path $HistoryFile -Leaf)
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
    Write-Step "HTML report generated: $HtmlFile" "OK"
} catch {
    Write-Step "HTML report: write failed - $($_.Exception.Message)" "ERROR"
}

# ============================================================================
#  OLD REPORT PURGE (new in v5.1)
#  The history CSV (Windows-Preflight-Cleaner-History.csv) and the baseline
#  (Windows-Preflight-Cleaner-Baseline.json) are never purged: they feed the
#  trend and the inter-run delta.
# ============================================================================
if ($RetainReportsDays -gt 0) {
    try {
        $cutoff = (Get-Date).AddDays(-$RetainReportsDays)
        $oldReports = Get-ChildItem -Path $ReportFolder -File -ErrorAction SilentlyContinue |
            Where-Object {
                $_.LastWriteTime -lt $cutoff -and
                ($_.Name -like "Windows-Preflight-Cleaner-*.html" -or $_.Name -like "Windows-Preflight-Cleaner-*.json" -or $_.Name -like "Transcript-*.log")
            }
        if ($oldReports) {
            $purgedCount = 0
            foreach ($f in $oldReports) {
                try { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop; $purgedCount++ } catch {}
            }
            if ($purgedCount -gt 0) {
                Write-Step "Report purge: $purgedCount file(s) older than $RetainReportsDays day(s) removed" "OK"
                $null = $Actions.Add("Automatic purge: $purgedCount old report(s) removed (retention $RetainReportsDays d)")
            }
        }
    } catch {
        Write-Step "Report purge: failed - $($_.Exception.Message)" "WARN"
    }
}

# ============================================================================
#  NOTIFICATION & WRAP-UP
# ============================================================================
Show-Notification -Title "Windows 11 cleanup complete" -Message "Disk gain: $(Format-GB $DiskGainGB) GB | Items removed: $($script:TotalFilesRemoved) | Duration: $Duration"

Write-Host ""
if (-not $Silent) {
    $openBrowser = Read-Host "Open the report in the browser? [Y/n]"
    if ($openBrowser -notmatch '^[Nn]') {
        try { Start-Process $HtmlFile } catch {}
    }
}
# In -Silent mode (e.g. scheduled task), the report is not opened automatically.

try { Stop-Transcript | Out-Null } catch {}

if (-not $Silent) {
    Write-Host ""
    Write-Host "====================================================" -ForegroundColor Magenta
    Read-Host "Press ENTER to close"
}

$finalExitCode = 0
if ($LockedTargets.Count -gt 0) { $finalExitCode = 1 }
exit $finalExitCode
