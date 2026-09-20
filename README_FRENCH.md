# Windows-Preflight-Cleaner

🇬🇧 [English version](README.md)

Script PowerShell autonome de maintenance pour Windows 11. Nettoie en toute securite 46+ caches systeme/applicatifs, journaux, fichiers temporaires et WinSxS via DISM, vide le cache DNS et la corbeille. Livre avec mode simulation, self-test a 17 verifications, codes de sortie et rapports HTML/JSON pour un deploiement multi-machines.

> Aucune suppression a l'aveugle. Un garde-fou de chemin rejette les cibles dangereuses, le mode simulation previsualise exactement ce qui se passerait avant d'agir, et les fichiers verrouilles sont signales honnetement plutot que masques silencieusement.

---

## Sommaire

- [Presentation](#presentation)
- [Captures d'ecran](#captures-decran)
- [Ce que le script nettoie](#ce-que-le-script-nettoie)
- [Ce que le script ne touche pas](#ce-que-le-script-ne-touche-pas)
- [Prerequis](#prerequis)
- [Premier lancement](#premier-lancement-pas-a-pas)
- [Raccourci bureau](#raccourci-bureau)
- [Parametres](#parametres)
- [Codes de sortie](#codes-de-sortie)
- [Rapports generes](#rapports-generes)
- [Deploiement multi-machines](#deploiement-multi-machines)
- [Depannage](#depannage)

---

## Presentation

`Windows-Preflight-Cleaner.ps1` nettoie les caches systeme et applicatifs, les journaux obsoletes, les fichiers temporaires multi-utilisateurs et les composants Windows (WinSxS via DISM) sur une machine Windows 11.

A chaque execution, il :

- traite **46 cibles de nettoyage fixes**, regroupees en categories (+ des cibles dynamiques : profils LibreWolf detectes, autres comptes Windows presents sur la machine) ;
- vide le cache DNS et la corbeille ;
- execute un nettoyage des composants Windows via DISM (`StartComponentCleanup`, avec `/ResetBase` en option) ;
- genere un **rapport HTML** (tableau de bord sombre), un **export JSON** complet, un **export CSV** d'historique et une **baseline JSON** pour calculer un delta par rapport a l'execution precedente ;
- purge automatiquement les anciens rapports au-dela d'un delai configurable.

Concu pour tourner aussi bien en interactif (poste de travail) qu'en silencieux (tache planifiee, deploiement multi-machines).

> **v5.3.0** — le script a ete renomme de `Nettoyage-Windows11-v5_2.ps1` vers `Windows-Preflight-Cleaner.ps1` et integralement traduit en anglais (sortie console, rapport HTML, les 46 noms de cibles). Il ne parse jamais de sortie de commande localisee (robocopy/DISM tournent en mode binaire silencieux), donc il fonctionne a l'identique sur une machine Windows en francais ou en anglais. Tout le formatage numerique (Go/pourcentage) utilise desormais un point decimal invariant, independant de la langue du systeme.

---

## Captures d'ecran

<p align="center">
  <img src="https://raw.githubusercontent.com/NephVx2/Windows-Preflight-Cleaner/main/screenshots/01_console-run-start.png" width="49%">
  <img src="https://raw.githubusercontent.com/NephVx2/Windows-Preflight-Cleaner/main/screenshots/06_html-report-dashboard.png" width="49%">
</p>

A gauche : un run console normal. A droite : l'en-tete du rapport HTML (tuiles de synthese, barre d'usage disque, tendance sur les derniers runs).

Note : l'interface du script (console et rapport HTML) est entierement en anglais depuis la traduction v5.3.0, y compris sur une machine Windows en francais — ce README reste en francais mais les captures ci-dessous montrent le texte reel affiche a l'ecran.

D'autres captures (les deux runs console, un second run sur une machine deja propre, et le detail complet du rapport HTML section par section) sont disponibles dans le dossier [`screenshots/`](https://github.com/NephVx2/Windows-Preflight-Cleaner/tree/main/screenshots).

---

## Ce que le script nettoie

<details>
<summary><strong>Windows Update</strong></summary>

| Cible | Chemin |
|---|---|
| Windows Update | `C:\Windows\SoftwareDistribution\Download` |

Le service `wuauserv` est arrete le temps du nettoyage, puis redemarre.
</details>

<details>
<summary><strong>Temporaires et caches systeme</strong></summary>

| Cible | Chemin |
|---|---|
| User Temp | `%TEMP%` |
| Windows Temp | `C:\Windows\Temp` |
| DirectX Cache | `%LOCALAPPDATA%\D3DSCache` |
| Delivery Optimization | `C:\Windows\SoftwareDistribution\DeliveryOptimization` |
| Explorer Thumbnails | `%LOCALAPPDATA%\Microsoft\Windows\Explorer` |
| WER ReportArchive | `C:\ProgramData\Microsoft\Windows\WER\ReportArchive` |
| WER ReportQueue | `C:\ProgramData\Microsoft\Windows\WER\ReportQueue` |
| WER Temp | `%LOCALAPPDATA%\Microsoft\Windows\WER\Temp` |
| CrashDumps | `%LOCALAPPDATA%\CrashDumps` |
</details>

<details>
<summary><strong>Journaux</strong></summary>

| Cible | Chemin |
|---|---|
| WindowsUpdate Logs | `C:\Windows\Logs\WindowsUpdate` |
| CBS Logs | `C:\Windows\Logs\CBS` |
| DISM Logs | `C:\Windows\Logs\DISM` |
| Panther Setup Logs | `C:\Windows\Panther` |
</details>

<details>
<summary><strong>Prefetch et dumps memoire</strong></summary>

| Cible | Chemin |
|---|---|
| Prefetch | `C:\Windows\Prefetch` |
| Memory Dumps (Minidump) | `C:\Windows\Minidump` |
| MEMORY.DMP | `C:\Windows\MEMORY.DMP` |
</details>

<details>
<summary><strong>Caches systeme unitaires</strong></summary>

| Cible | Chemin |
|---|---|
| IconCache.db | `%LOCALAPPDATA%\IconCache.db` |
| FNTCACHE.DAT | `C:\Windows\System32\FNTCACHE.DAT` |

Le service `FontCache` est arrete le temps du nettoyage, puis redemarre.
</details>

<details>
<summary><strong>Outils de developpement</strong></summary>

| Cible | Chemin |
|---|---|
| npm Cache | `%APPDATA%\npm-cache` |
| pip Cache | `%LOCALAPPDATA%\pip\Cache` |
| cargo Cache | `%USERPROFILE%\.cargo\registry\cache` |
| VS Code Cache | `%APPDATA%\Code\Cache` |
| VS Code CachedData | `%APPDATA%\Code\CachedData` |
| VS Code Logs | `%APPDATA%\Code\logs` |
| VS Code GPUCache | `%APPDATA%\Code\GPUCache` |
</details>

<details>
<summary><strong>WebView2</strong></summary>

Composant Chromium independant d'Edge, utilise par Widgets, Teams, et diverses applications pour le rendu web integre — cache uniquement, se regenere automatiquement, sans risque.

| Cible | Chemin |
|---|---|
| WebView2 Cache | `%LOCALAPPDATA%\Microsoft\EdgeWebView\User Data\Default\Cache` |
| WebView2 Code Cache | `%LOCALAPPDATA%\Microsoft\EdgeWebView\User Data\Default\Code Cache` |
| WebView2 GPUCache | `%LOCALAPPDATA%\Microsoft\EdgeWebView\User Data\Default\GPUCache` |
</details>

<details>
<summary><strong>Historique d'acces recents</strong></summary>

JumpLists du Demarrer/barre des taches — purement cosmetique/vie privee, recree automatiquement a l'usage.

| Cible | Chemin |
|---|---|
| Automatic JumpLists | `%APPDATA%\Microsoft\Windows\Recent\AutomaticDestinations` |
| Custom JumpLists | `%APPDATA%\Microsoft\Windows\Recent\CustomDestinations` |
</details>

<details>
<summary><strong>NVIDIA</strong></summary>

| Cible | Chemin |
|---|---|
| NVIDIA DXCache | `%LOCALAPPDATA%\NVIDIA\DXCache` |
| NVIDIA GLCache | `%LOCALAPPDATA%\NVIDIA\GLCache` |
| NVIDIA OptixCache | `%LOCALAPPDATA%\NVIDIA\OptixCache` |
</details>

<details>
<summary><strong>Spotify</strong></summary>

| Cible | Chemin |
|---|---|
| Spotify Storage Cache | `%LOCALAPPDATA%\Spotify\Storage` |
| Spotify Data Cache | `%LOCALAPPDATA%\Spotify\Data` |
</details>

<details>
<summary><strong>Steam</strong> (conditionnel — traite uniquement si detecte via <code>HKCU:\Software\Valve\Steam</code>)</summary>

| Cible | Chemin |
|---|---|
| Steam AppCache | `<dossier Steam>\appcache` |
| Steam HtmlCache | `<dossier Steam>\htmlcache` |
| Steam Incomplete Downloads | `<dossier Steam>\steamapps\downloading` |
</details>

<details>
<summary><strong>Navigateurs</strong></summary>

| Cible | Chemin |
|---|---|
| Brave Cache | `%LOCALAPPDATA%\BraveSoftware\Brave-Browser\User Data\Default\Cache` |
| Brave Code Cache | `%LOCALAPPDATA%\BraveSoftware\Brave-Browser\User Data\Default\Code Cache` |
| Brave GPU Cache | `%LOCALAPPDATA%\BraveSoftware\Brave-Browser\User Data\Default\GPUCache` |
| LibreWolf Cache [profil] | couple Cache/StartupCache genere par profil LibreWolf detecte automatiquement sur la machine (0, 1 ou plusieurs) |
| LibreWolf StartupCache [profil] | — |
</details>

<details>
<summary><strong>Profils temp multi-utilisateurs</strong> (cible dynamique)</summary>

| Cible | Chemin |
|---|---|
| Temp [nom_compte] | `C:\Users\<compte>\AppData\Local\Temp` pour chaque compte Windows present sur la machine autre que l'utilisateur courant |
</details>

<details>
<summary><strong>Actions hors cibles</strong> (executees a chaque run, hors mode <code>-DryRun</code>)</summary>

| Action | Detail |
|---|---|
| Cache DNS | `ipconfig /flushdns` |
| Corbeille | vidage complet (tous les lecteurs) |
| Point de restauration systeme | optionnel, `-CreateRestorePoint` — soumis au throttle Windows de 1 point/24h pour `MODIFY_SETTINGS` |
| DISM StartComponentCleanup | nettoyage des anciennes versions de composants WinSxS. Avec `-ResetBase` (option separee, confirmation interactive requise) : suppression **definitive** des anciennes versions, plus de rollback de mise a jour possible ensuite |
</details>

---

## Ce que le script ne touche pas

- **Aucun document, photo, projet ou fichier utilisateur** — uniquement des caches, journaux et fichiers temporaires regeneres automatiquement par Windows ou les applications concernees.
- **Aucune donnee de navigateur autre que le cache** — historique, mots de passe, favoris, cookies, sessions ouvertes : non touches.
- **Le registre Windows n'est jamais modifie.**
- Un garde-fou de securite interne (`Test-SafeCleanupPath`) refuse automatiquement toute cible situee a moins de 2 niveaux sous la racine d'un lecteur (`C:\`, `C:\Windows`, `C:\Users`...), pour se proteger contre une future erreur de configuration qui ferait pointer le nettoyage vers un dossier systeme trop large.

---

## Prerequis

- Windows 11 (fonctionne aussi sur Windows 10, non teste en priorite).
- PowerShell 5.1 (integre a Windows) ou PowerShell 7+.
- Droits administrateur. Le script s'auto-eleve si lance depuis une session non-admin (fenetre UAC).
- `robocopy.exe` et `DISM.exe` presents (integres a Windows par defaut).
- Le dossier de rapports doit etre inscriptible : `%USERPROFILE%\Desktop\Maintenance_Reports\Windows-Preflight-Cleaner` (cree automatiquement au premier lancement si absent).
- Si le script est signe numeriquement (recommande en environnement `-ExecutionPolicy AllSigned`/`RemoteSigned`) : le certificat de signature doit etre approuve sur la machine cible, sans quoi PowerShell refusera l'execution.

---

## Premier lancement (pas a pas)

1. Copier `Windows-Preflight-Cleaner.ps1` sur la machine cible (par exemple dans un dossier `C:\Scripts\Maintenance`).

2. Ouvrir un terminal PowerShell (pas besoin de le lancer en admin a la main, le script s'auto-eleve).

3. Verifier les prerequis systeme **sans rien nettoyer** :

   ```powershell
   .\Windows-Preflight-Cleaner.ps1 -SelfTest
   ```

   Execute 17 verifications automatiques (droits admin, presence de robocopy/DISM, services requis, fonctions internes du script) et affiche PASS/FAIL pour chacune. Le script quitte ensuite sans avoir touche a aucun fichier. Code de sortie attendu : `0` (voir [Codes de sortie](#codes-de-sortie)).

4. Faire une **simulation complete** avant le premier nettoyage reel, pour voir ce qui serait supprime sans rien supprimer :

   ```powershell
   .\Windows-Preflight-Cleaner.ps1 -DryRun
   ```

   Calcule les gains potentiels par cible, genere un rapport HTML `[MODE SIMULATION]` et n'execute ni suppression, ni DISM, ni vidage DNS/corbeille.

5. Lire le rapport HTML genere (le script propose de l'ouvrir automatiquement, sauf en mode `-Silent`) pour verifier que les cibles et les volumes estimes correspondent aux attentes sur cette machine.

6. Lancer le **premier nettoyage reel** :

   ```powershell
   .\Windows-Preflight-Cleaner.ps1
   ```

   Repondre aux invites interactives (ouverture du rapport, confirmation ENTREE en fin de run). Le nettoyage complet dure generalement moins de 10 secondes hors DISM (`StartComponentCleanup` peut prendre plusieurs minutes selon l'etat du dossier WinSxS).

7. *(Optionnel, pour un deploiement automatise)* une fois le comportement valide manuellement, planifier le run via le Planificateur de taches Windows avec `-Silent` (voir [Deploiement multi-machines](#deploiement-multi-machines)).

---

## Raccourci bureau

Pour une machine que tu nettoies a la main de temps en temps, un raccourci bureau est plus rapide que d'ouvrir un terminal a chaque fois.

1. Clic droit sur le Bureau → **Nouveau** → **Raccourci**.
2. Dans **"Entrez l'emplacement de l'element"**, colle l'une des deux commandes ci-dessous (choisis celle qui correspond a ta version de PowerShell — voir le tableau des options pour le detail de chaque partie), puis **Suivant** → donne-lui un nom → **Terminer**.

| Version de PowerShell | Commande |
|---|---|
| **PowerShell 7+** (`pwsh.exe`, installation separee) | `pwsh.exe -NoProfile -ExecutionPolicy Bypass -File "C:\chemin\vers\Windows-Preflight-Cleaner.ps1"` |
| **Windows PowerShell 5.1** (`powershell.exe`, integre a toute installation de Windows, aucune installation requise) | `powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\chemin\vers\Windows-Preflight-Cleaner.ps1"` |

Le script fonctionne a l'identique dans les deux cas (son `-SelfTest` verifie la compatibilite avec les deux editions) — utilise celle que tu as deja. En cas de doute, `powershell.exe` est toujours present et ne demande aucune etape supplementaire.

**Ce que fait concretement la commande, option par option :**

| Option | Ce qu'elle fait |
|---|---|
| `pwsh.exe` / `powershell.exe` | Le moteur PowerShell lui-meme — PowerShell 7+ ou la version 5.1 native de Windows, selon le cas. |
| `-NoProfile` | Ignore le chargement de ton profil PowerShell personnel (`$PROFILE`) au demarrage. Plus rapide, et evite qu'une fonction/alias/module personnalise que tu as configure n'interfere avec l'environnement du script. |
| `-ExecutionPolicy Bypass` | Contourne la politique d'execution pour **ce seul process** — ca ne modifie pas ta politique systeme globale. Necessaire car les scripts telecharges depuis Internet sont marques du "Mark of the Web", et la politique courante `RemoteSigned` bloque sinon leur execution. |
| `-File "..."` | Execute ce fichier `.ps1` precis, au chemin indique. |

Le script se re-eleve lui-meme (invite UAC) des qu'il detecte qu'il ne tourne pas en Administrateur, donc rien dans le raccourci lui-meme n'a besoin d'une case "Executer en tant qu'administrateur" pour *fonctionner*.

**Ceci dit, un simple double-clic ouvre quand meme la fenetre console classique (`conhost`)**, dont le rendu de police est legerement plus rugueux que la fenetre Windows Terminal moderne utilisee par le **"Executer en tant qu'administrateur"** propre a l'Explorateur — et peut occasionnellement decaler des lignes deja affichees si tu redimensionnes la fenetre en cours de run (purement cosmetique, voir [Depannage](#depannage)). Si tu preferes le rendu le plus propre des le depart, fais un clic droit sur le raccourci et choisis **"Executer en tant qu'administrateur"** plutot qu'un double-clic — fonctionnellement identique, juste une fenetre plus soignee.

---

## Parametres

| Parametre | Description |
|---|---|
| `-Silent` | Supprime les invites interactives (confirmation `-ResetBase`, pause ENTREE finale) et n'ouvre pas automatiquement le rapport HTML. A utiliser systematiquement pour une tache planifiee. |
| `-DryRun` | Mode simulation : calcule les gains potentiels sans rien supprimer, sans executer DISM, sans vider le cache DNS ni la corbeille. |
| `-SelfTest` | Verifie les prerequis et 10 fonctions internes du script (formatage, garde-fou de securite, detection de verrouillage, round-trip JSON/CSV, detection LibreWolf/Steam), puis quitte sans nettoyer. 17 verifications au total. |
| `-CreateRestorePoint` | Cree un point de restauration systeme avant le nettoyage DISM. Soumis au throttle Windows de 1 point/24h pour `MODIFY_SETTINGS` (peut echouer silencieusement — comportement normal de Windows, pas un bug). |
| `-ResetBase` | Ajoute `/ResetBase` au nettoyage DISM : supprime **definitivement** les anciennes versions de composants WinSxS. Plus de rollback de mise a jour possible ensuite. Demande une confirmation interactive, sauf si `-Silent` est utilise. |
| `-SkipTargets "Nom1","Nom2"` | Liste de noms de cibles a ignorer (noms exacts affiches dans la console). Une faute de frappe ne correspondant a aucune cible reelle declenche un avertissement explicite en fin de run. |
| `-OnlyTargets "Nom1","Nom2"` | Liste de noms de cibles a traiter exclusivement (toutes les autres sont ignorees). Meme detection de faute de frappe que `-SkipTargets`. |
| `-RetainReportsDays <nombre>` | Nombre de jours de retention des rapports HTML/JSON/Transcript avant purge automatique (defaut : `60`). Le CSV d'historique et la baseline JSON ne sont jamais purges. Utiliser `0` pour desactiver la purge. |

**Exemples :**

```powershell
.\Windows-Preflight-Cleaner.ps1 -DryRun
.\Windows-Preflight-Cleaner.ps1 -Silent -SkipTargets "Prefetch","Steam AppCache"
.\Windows-Preflight-Cleaner.ps1 -CreateRestorePoint -ResetBase
.\Windows-Preflight-Cleaner.ps1 -RetainReportsDays 30
```

---

## Codes de sortie

Utile pour integrer le script a une supervision multi-machines sans avoir a parser le transcript texte.

| Code | Signification |
|---|---|
| `0` | Run complet, rien a signaler |
| `1` | Run complet mais avec des cibles verrouillees/protegees detectees (fichiers en cours d'utilisation au moment du nettoyage), **ou** `-SelfTest` en echec |
| `2` | Erreur fatale non geree (capturee par un filet de securite global qui affiche le message d'erreur avant de sortir) |

Verification apres un run :

```powershell
echo $LASTEXITCODE
```

---

## Rapports generes

A chaque run (y compris `-DryRun`, et partiellement `-SelfTest`), le script ecrit dans :

```
%USERPROFILE%\Desktop\Maintenance_Reports\Windows-Preflight-Cleaner\
```

| Fichier | Contenu |
|---|---|
| `Windows-Preflight-Cleaner-AAAA-MM-JJ_HH-mm-ss.html` | Rapport visuel : tuiles de synthese, barre d'usage disque, tendance sur les 10 derniers runs, detail par cible avec statut colore, journal des actions |
| `Windows-Preflight-Cleaner-AAAA-MM-JJ_HH-mm-ss.json` | Export complet de toutes les donnees du run |
| `Transcript-AAAA-MM-JJ_HH-mm-ss.log` | Transcript PowerShell brut |
| `Windows-Preflight-Cleaner-History.csv` | Historique cumulatif (append), jamais purge |
| `Windows-Preflight-Cleaner-Baseline.json` | Etat du dernier run, pour calculer le delta au run suivant, jamais purge |

Les rapports HTML/JSON/Transcript plus anciens que `-RetainReportsDays` (60 jours par defaut) sont purges automatiquement en fin de run.

Dans le rapport HTML, chaque cible affiche un badge de statut :

| Badge | Signification |
|---|---|
| ✅ vert | Nettoye |
| 🟡 `~` | Partiellement nettoye (verrouille/protege en partie) |
| 🔴 `!` | Verrouille ou protege (rien n'a pu etre supprime) |
| ⬜ `-` | Deja vide |
| 🟡 `≈` | Simulation (`-DryRun` uniquement) |

---

## Deploiement multi-machines

Le script est autonome (aucune dependance externe autre que `robocopy.exe` et `DISM.exe`, integres a Windows).

1. **Distribuer** le fichier `.ps1` (copie reseau, GPO, outil de deploiement, ou clone de ce depot) vers un dossier local sur chaque machine.

2. **Approuver le certificat de signature** si une politique d'execution stricte est en place (`-ExecutionPolicy AllSigned`/`RemoteSigned`) — magasin "Autorites de certification racines de confiance" ou "Personnes de confiance" selon la politique retenue. Sans quoi PowerShell refusera l'execution.

3. **Executer `-SelfTest` en premier** sur chaque machine pour valider les prerequis avant tout nettoyage reel. Le code de sortie permet d'automatiser cette verification.

4. **Planifier via le Planificateur de taches Windows** (ou l'equivalent en environnement d'entreprise), avec `-Silent` obligatoire pour eviter tout blocage sur une invite interactive :

   | Champ | Valeur |
   |---|---|
   | Programme/script | `pwsh.exe` (ou `powershell.exe`) |
   | Arguments | `-NoProfile -ExecutionPolicy Bypass -File "C:\Scripts\Maintenance\Windows-Preflight-Cleaner.ps1" -Silent` |
   | Executer avec les autorisations maximales | Oui (necessaire pour les droits administrateur) |

5. **Superviser via `$LASTEXITCODE`** plutot que le parsing du transcript : un code `1` ou `2` justifie une verification manuelle ou une alerte dans l'outil de supervision.

6. Le CSV d'historique et la baseline JSON sont **propres a chaque machine** (stockes localement dans le profil de l'utilisateur qui execute le script) : aucune donnee n'est centralisee automatiquement. Une remontee centralisee (partage reseau, collecte des JSON) reste a mettre en place separement si necessaire.

---

## Depannage

<details>
<summary><strong>Une cible apparait en rouge (!) ou jaune (~) dans le rapport</strong></summary>

Des fichiers etaient ouverts par une application au moment du nettoyage (ex : navigateur en cours d'execution pendant le nettoyage de son cache). Fermer l'application concernee et relancer le script pour finir le nettoyage de cette cible. Le resume de fin de run liste les cibles concernees avec le volume exact non recupere.

<p align="center">
  <img src="https://raw.githubusercontent.com/NephVx2/Windows-Preflight-Cleaner/main/screenshots/09_html-report-detail-table-locked.png" width="80%">
</p>

Le tableau de detail (ci-dessus) et le journal des actions signalent tous deux les cibles partielles (`~`) et verrouillees (`!`) avec une bordure de gauche coloree et un decompte explicite, ex. `VS Code Logs : partial cleanup (41 removed, 29 locked)`.
</details>

<details>
<summary><strong><code>-OnlyTargets</code> ou <code>-SkipTargets</code> semble ne rien faire</strong></summary>

Verifier l'orthographe exacte du nom de cible (voir [Ce que le script nettoie](#ce-que-le-script-nettoie), ou les noms affiches dans la console lors d'un run normal). Le script affiche un avertissement explicite en fin de run si un nom fourni ne correspond a aucune cible reelle.
</details>

<details>
<summary><strong><code>-SelfTest</code> indique un FAIL</strong></summary>

Lire le libelle du test en echec : il correspond generalement a un prerequis systeme manquant (droits admin, service Windows arrete, robocopy/DISM absent d'un environnement restreint, dossier rapports non inscriptible). Corriger le prerequis puis relancer `-SelfTest`.
</details>

<details>
<summary><strong>Le point de restauration echoue systematiquement</strong></summary>

Comportement normal de Windows si un point a deja ete cree dans les dernieres 24h pour le type `MODIFY_SETTINGS` (throttle Windows, pas un bug du script).
</details>

<details>
<summary><strong>Le gain disque mesure est proche de 0 alors que des elements ont ete supprimes</strong></summary>

Normal : Windows peut reoccuper l'espace libere quasi instantanement (cache disque, fichiers systeme temporaires generes en parallele). Se referer plutot a la colonne "Gain" par cible dans le rapport HTML, qui mesure precisement l'espace libere pour chaque dossier nettoye.
</details>

<details>
<summary><strong>Des lignes semblent decalees apres redimensionnement de la fenetre console</strong></summary>

Redimensionner la console en cours de run (ou apres la fin, avant de la fermer) peut decaler visuellement des lignes deja affichees. C'est une limitation inherente au reflow de `conhost`/Windows Terminal, pas un bug du script : chaque ligne console est composee de plusieurs segments `Write-Host` colores separes, et le host console ne les redessine pas toujours correctement face a une nouvelle largeur. Purement cosmetique — les donnees reelles (HTML/JSON/CSV/transcript) ne sont affectees dans aucun cas. Evite de redimensionner la fenetre pendant que le script tourne, ou utilise "Executer en tant qu'administrateur" plutot qu'un simple double-clic, qui s'affiche via le Windows Terminal, plus tolerant au redimensionnement (voir [Raccourci bureau](#raccourci-bureau)).
</details>

---

<sub>Windows-Preflight-Cleaner v5.3.0 — construit et durci via des tests iteratifs en conditions reelles.</sub>
