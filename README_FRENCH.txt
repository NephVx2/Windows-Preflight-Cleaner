================================================================================
  Nettoyage-Windows11 v5.2 - README
  Suite de maintenance et nettoyage pour Windows 11
================================================================================

SOMMAIRE
--------
 1. Presentation
 2. Ce que le script nettoie (detail complet)
 3. Ce que le script ne touche PAS
 4. Prerequis
 5. Premier lancement (pas a pas)
 6. Parametres disponibles
 7. Codes de sortie (supervision / taches planifiees)
 8. Rapports generes
 9. Deploiement multi-machines
10. Depannage rapide


================================================================================
 1. PRESENTATION
================================================================================

Nettoyage-Windows11 est un script PowerShell autonome qui nettoie les caches
systeme et applicatifs, les journaux obsoletes, les fichiers temporaires
multi-utilisateurs et les composants Windows (WinSxS via DISM) sur une machine
Windows 11.

A chaque execution, il :
  - traite 46 cibles de nettoyage fixes, regroupees en categories (+ des
    cibles dynamiques : profils LibreWolf detectes, autres comptes Windows
    presents sur la machine) ;
  - vide le cache DNS et la corbeille ;
  - execute un nettoyage des composants Windows via DISM
    (StartComponentCleanup, avec /ResetBase en option) ;
  - genere un rapport HTML (tableau de bord sombre), un export JSON complet,
    un export CSV d'historique et une baseline JSON pour calculer un delta
    par rapport a l'execution precedente ;
  - purge automatiquement les anciens rapports au-dela d'un delai configurable.

Le script est concu pour tourner aussi bien en interactif (poste de travail)
qu'en silencieux (tache planifiee, deploiement multi-machines).


================================================================================
 2. CE QUE LE SCRIPT NETTOIE (DETAIL COMPLET)
================================================================================

Windows Update
  - Windows Update .......... C:\Windows\SoftwareDistribution\Download
    (le service wuauserv est arrete le temps du nettoyage, puis redemarre)

Temporaires et caches systeme
  - Temp Utilisateur ......... %TEMP%
  - Temp Windows ............. C:\Windows\Temp
  - DirectX Cache ............ %LOCALAPPDATA%\D3DSCache
  - Delivery Optimization .... C:\Windows\SoftwareDistribution\DeliveryOptimization
  - Miniatures Explorer ...... %LOCALAPPDATA%\Microsoft\Windows\Explorer
  - WER ReportArchive ........ C:\ProgramData\Microsoft\Windows\WER\ReportArchive
  - WER ReportQueue .......... C:\ProgramData\Microsoft\Windows\WER\ReportQueue
  - WER Temp .................. %LOCALAPPDATA%\Microsoft\Windows\WER\Temp
  - CrashDumps ................ %LOCALAPPDATA%\CrashDumps

Journaux
  - Logs WindowsUpdate ....... C:\Windows\Logs\WindowsUpdate
  - Logs CBS .................. C:\Windows\Logs\CBS
  - Logs DISM .................. C:\Windows\Logs\DISM
  - Panther Setup Logs ........ C:\Windows\Panther

Prefetch et dumps memoire
  - Prefetch .................. C:\Windows\Prefetch
  - Memory Dumps (Minidump) ... C:\Windows\Minidump
  - MEMORY.DMP ................. C:\Windows\MEMORY.DMP

Caches systeme unitaires
  - IconCache.db .............. %LOCALAPPDATA%\IconCache.db
  - FNTCACHE.DAT ............... C:\Windows\System32\FNTCACHE.DAT
    (le service FontCache est arrete le temps du nettoyage, puis redemarre)

Outils de developpement
  - Cache npm .................. %APPDATA%\npm-cache
  - Cache pip ................... %LOCALAPPDATA%\pip\Cache
  - Cache cargo .................. %USERPROFILE%\.cargo\registry\cache
  - VS Code Cache ............... %APPDATA%\Code\Cache
  - VS Code CachedData ........... %APPDATA%\Code\CachedData
  - VS Code Logs .................. %APPDATA%\Code\logs
  - VS Code GPUCache ............... %APPDATA%\Code\GPUCache

WebView2 (composant Chromium independant d'Edge, utilise par Widgets, Teams,
et diverses applications pour le rendu web integre - cache uniquement, se
regenere automatiquement, sans risque)
  - WebView2 Cache ................. %LOCALAPPDATA%\Microsoft\EdgeWebView\User Data\Default\Cache
  - WebView2 Code Cache ............ %LOCALAPPDATA%\Microsoft\EdgeWebView\User Data\Default\Code Cache
  - WebView2 GPUCache .............. %LOCALAPPDATA%\Microsoft\EdgeWebView\User Data\Default\GPUCache

Historique d'acces recents (JumpLists du Demarrer/barre des taches -
purement cosmetique/vie privee, recree automatiquement a l'usage)
  - JumpLists Automatiques ......... %APPDATA%\Microsoft\Windows\Recent\AutomaticDestinations
  - JumpLists Manuelles ............ %APPDATA%\Microsoft\Windows\Recent\CustomDestinations

NVIDIA
  - NVIDIA DXCache .................. %LOCALAPPDATA%\NVIDIA\DXCache
  - NVIDIA GLCache ................... %LOCALAPPDATA%\NVIDIA\GLCache
  - NVIDIA OptixCache ................. %LOCALAPPDATA%\NVIDIA\OptixCache

Spotify
  - Spotify Storage Cache ............. %LOCALAPPDATA%\Spotify\Storage
  - Spotify Data Cache ................. %LOCALAPPDATA%\Spotify\Data

Steam (traite uniquement si Steam est detecte via le registre
HKCU:\Software\Valve\Steam - ignore proprement sinon)
  - Steam AppCache ...................... <dossier Steam>\appcache
  - Steam HtmlCache ...................... <dossier Steam>\htmlcache
  - Steam Downloads incomplets ............ <dossier Steam>\steamapps\downloading

Navigateurs
  - Brave Cache ............................ %LOCALAPPDATA%\BraveSoftware\Brave-Browser\User Data\Default\Cache
  - Brave Code Cache ........................ %LOCALAPPDATA%\BraveSoftware\Brave-Browser\User Data\Default\Code Cache
  - Brave GPU Cache .......................... %LOCALAPPDATA%\BraveSoftware\Brave-Browser\User Data\Default\GPUCache
  - LibreWolf Cache [profil] .................. un couple Cache/StartupCache
  - LibreWolf StartupCache [profil] ............ genere par profil LibreWolf
                                                  detecte automatiquement sur
                                                  la machine (0, 1 ou plusieurs)

Profils temp multi-utilisateurs (nouveau v5 - cible dynamique)
  - Temp [nom_compte] ......................... C:\Users\<compte>\AppData\Local\Temp
                                                  pour chaque compte Windows
                                                  present sur la machine autre
                                                  que l'utilisateur courant

Actions hors cibles (executees a chaque run, hors mode -DryRun)
  - Cache DNS .................................. ipconfig /flushdns
  - Corbeille ................................... vidage complet (tous les
                                                    lecteurs)
  - Point de restauration systeme (optionnel, -CreateRestorePoint) - soumis
    au throttle Windows de 1 point/24h pour le type MODIFY_SETTINGS
  - DISM StartComponentCleanup .................. nettoyage des anciennes
                                                    versions de composants
                                                    Windows (WinSxS).
                                                    Avec -ResetBase (option
                                                    separee, confirmation
                                                    interactive requise) :
                                                    suppression DEFINITIVE
                                                    des anciennes versions,
                                                    plus de rollback de mise
                                                    a jour possible ensuite.


================================================================================
 3. CE QUE LE SCRIPT NE TOUCHE PAS
================================================================================

  - Aucun document, photo, projet ou fichier utilisateur : uniquement des
    caches, journaux et fichiers temporaires regeneres automatiquement par
    Windows ou les applications concernees.
  - Aucune donnee de navigateur autre que le cache (historique, mots de
    passe, favoris, cookies, sessions ouvertes : non touches).
  - Le registre Windows n'est jamais modifie.
  - Un garde-fou de securite interne (Test-SafeCleanupPath) refuse
    automatiquement toute cible situee a moins de 2 niveaux sous la racine
    d'un lecteur (C:\, C:\Windows, C:\Users...), pour se proteger contre une
    future erreur de configuration qui ferait pointer le nettoyage vers un
    dossier systeme trop large.


================================================================================
 4. PREREQUIS
================================================================================

  - Windows 11 (fonctionne aussi sur Windows 10, non teste en priorite).
  - PowerShell 5.1 (integre a Windows) ou PowerShell 7+.
  - Droits administrateur. Le script s'auto-eleve si lance depuis une
    session non-admin (fenetre UAC).
  - robocopy.exe et DISM.exe presents (integres a Windows par defaut).
  - Le dossier de rapports doit etre inscriptible :
    %USERPROFILE%\Desktop\Rapports_Maintenance\Nettoyage systeme
    (cree automatiquement au premier lancement si absent).
  - Si le script est signe numeriquement (recommande en environnement
    -ExecutionPolicy AllSigned/RemoteSigned) : le certificat de signature
    doit etre approuve sur la machine cible, sans quoi PowerShell refusera
    l'execution.


================================================================================
 5. PREMIER LANCEMENT (PAS A PAS)
================================================================================

  1. Copier Nettoyage-Windows11-v5_2.ps1 sur la machine cible (par exemple
     dans un dossier C:\Scripts\Maintenance).

  2. Ouvrir un terminal PowerShell (pas besoin de le lancer en admin a la
     main, le script s'auto-eleve).

  3. Verifier les prerequis systeme SANS rien nettoyer :

         .\Nettoyage-Windows11-v5_2.ps1 -SelfTest

     Cette commande execute 17 verifications automatiques (droits admin,
     presence de robocopy/DISM, services requis, fonctions internes du
     script) et affiche PASS/FAIL pour chacune. Le script quitte ensuite
     sans avoir touche a aucun fichier.

     Code de sortie attendu : 0 (voir section 7 pour le detail).

  4. Faire une simulation complete AVANT le premier nettoyage reel, pour
     voir ce qui serait supprime sans rien supprimer :

         .\Nettoyage-Windows11-v5_2.ps1 -DryRun

     Cette commande calcule les gains potentiels par cible, genere un
     rapport HTML "[MODE SIMULATION]" et n'execute ni suppression, ni
     DISM, ni vidage DNS/corbeille.

  5. Lire le rapport HTML genere (le script propose de l'ouvrir
     automatiquement, sauf en mode -Silent) pour verifier que les cibles
     et les volumes estimes correspondent aux attentes sur cette machine.

  6. Lancer le premier nettoyage reel :

         .\Nettoyage-Windows11-v5_2.ps1

     Repondre aux invites interactives (ouverture du rapport, confirmation
     ENTREE en fin de run). Le nettoyage complet dure generalement moins de
     10 secondes hors DISM (DISM StartComponentCleanup peut prendre
     plusieurs minutes selon l'etat du dossier WinSxS).

  7. (Optionnel, pour un deploiement automatise) une fois le comportement
     valide manuellement, planifier le run via le Planificateur de taches
     Windows avec le parametre -Silent (voir section 9).


================================================================================
 6. PARAMETRES DISPONIBLES
================================================================================

  -Silent
      Supprime les invites interactives (confirmation -ResetBase, pause
      ENTREE finale) et n'ouvre pas automatiquement le rapport HTML.
      A utiliser systematiquement pour une tache planifiee.

  -DryRun
      Mode simulation : calcule les gains potentiels sans rien supprimer,
      sans executer DISM, sans vider le cache DNS ni la corbeille.

  -SelfTest
      Verifie les prerequis (droits admin, robocopy, DISM, services,
      dossier rapports inscriptible) et 10 fonctions internes du script
      (formatage, garde-fou de securite, detection de verrouillage de
      fichiers, round-trip JSON/CSV, detection LibreWolf/Steam), puis
      quitte sans nettoyer. 17 verifications au total.

  -CreateRestorePoint
      Cree un point de restauration systeme avant le nettoyage DISM.
      Soumis au throttle Windows de 1 point/24h pour le type
      MODIFY_SETTINGS (peut echouer silencieusement si un point a deja
      ete cree recemment par un autre processus - c'est un comportement
      normal de Windows, pas un bug du script).

  -ResetBase
      Ajoute /ResetBase au nettoyage DISM : supprime DEFINITIVEMENT les
      anciennes versions de composants WinSxS. Plus de rollback de mise a
      jour possible ensuite. Demande une confirmation interactive
      explicite, sauf si -Silent est utilise (dans ce cas, l'operation
      est executee sans confirmation - a n'utiliser en silencieux qu'en
      toute connaissance de cause).

  -SkipTargets "Nom1","Nom2"
      Liste de noms de cibles a ignorer (utiliser les noms exacts affiches
      dans la console, par exemple "Cache npm"). Si un nom fourni ne
      correspond a aucune cible reelle du run (faute de frappe), un
      avertissement explicite s'affiche en fin d'execution.

  -OnlyTargets "Nom1","Nom2"
      Liste de noms de cibles a traiter exclusivement (toutes les autres
      sont ignorees). Meme detection de faute de frappe que -SkipTargets.

  -RetainReportsDays <nombre>
      Nombre de jours de retention des rapports HTML/JSON/Transcript avant
      purge automatique en fin de run (defaut : 60). Le CSV d'historique
      et la baseline JSON ne sont jamais purges. Utiliser
      -RetainReportsDays 0 pour desactiver la purge.

  Exemples :

      .\Nettoyage-Windows11-v5_2.ps1 -DryRun
      .\Nettoyage-Windows11-v5_2.ps1 -Silent -SkipTargets "Prefetch","Steam AppCache"
      .\Nettoyage-Windows11-v5_2.ps1 -CreateRestorePoint -ResetBase
      .\Nettoyage-Windows11-v5_2.ps1 -RetainReportsDays 30


================================================================================
 7. CODES DE SORTIE (SUPERVISION / TACHES PLANIFIEES)
================================================================================

  Utile pour integrer le script a une supervision multi-machines sans avoir
  a parser le transcript texte.

      0 = run complet, rien a signaler
      1 = run complet mais avec des cibles verrouillees/protegees
          detectees (fichiers en cours d'utilisation au moment du
          nettoyage), ou -SelfTest en echec
      2 = erreur fatale non geree (capturee par un filet de securite
          global qui affiche le message d'erreur avant de sortir)

  Verification apres un run : $LASTEXITCODE (PowerShell)


================================================================================
 8. RAPPORTS GENERES
================================================================================

  A chaque run (y compris -DryRun et -SelfTest partiellement), le script
  ecrit dans :

      %USERPROFILE%\Desktop\Rapports_Maintenance\Nettoyage systeme\

  les fichiers suivants :

      Nettoyage-AAAA-MM-JJ_HH-mm-ss.html   Rapport visuel (tableau de bord
                                            sombre : tuiles de synthese,
                                            barre d'usage disque, tendance
                                            sur les 10 derniers runs, detail
                                            par cible avec statut colore,
                                            journal des actions)
      Nettoyage-AAAA-MM-JJ_HH-mm-ss.json   Export complet de toutes les
                                            donnees du run
      Transcript-AAAA-MM-JJ_HH-mm-ss.log   Transcript PowerShell brut
      Historique_v5.csv                    Historique cumulatif (append),
                                            jamais purge
      Baseline_v5.json                     Etat du dernier run, pour
                                            calculer le delta au run
                                            suivant, jamais purge

  Les rapports HTML/JSON/Transcript plus anciens que -RetainReportsDays
  (60 jours par defaut) sont purges automatiquement en fin de run.

  Dans le rapport HTML, chaque cible affiche un badge de statut :
      [check]  vert    Nettoye
      [~]      jaune   Partiellement nettoye (verrouille/protege en partie)
      [!]      rouge   Verrouille ou protege (rien n'a pu etre supprime)
      [-]      gris    Deja vide
      [~=]     jaune   Simulation (-DryRun uniquement)


================================================================================
 9. DEPLOIEMENT MULTI-MACHINES
================================================================================

  Le script est concu comme un fichier autonome (aucune dependance externe
  autre que robocopy.exe et DISM.exe, integres a Windows). Pour un
  deploiement sur plusieurs machines :

  1. Distribuer le fichier .ps1 (copie reseau, GPO, outil de deploiement,
     ou clone du depot Git) vers un dossier local sur chaque machine.

  2. Si une politique d'execution stricte est en place
     (-ExecutionPolicy AllSigned ou RemoteSigned), s'assurer que le
     certificat de signature du script est approuve sur chaque machine
     cible (magasin de certificats "Autorites de certification racines
     de confiance" ou "Personnes de confiance" selon la politique
     retenue), sans quoi PowerShell refusera l'execution.

  3. Sur chaque machine, executer -SelfTest en premier pour valider les
     prerequis avant tout nettoyage reel (voir section 5, etape 3). Le
     code de sortie (section 7) permet d'automatiser cette verification.

  4. Planifier l'execution via le Planificateur de taches Windows (ou
     l'equivalent en environnement d'entreprise), avec le parametre
     -Silent obligatoire pour eviter tout blocage sur une invite
     interactive :

         Programme/script   : pwsh.exe (ou powershell.exe)
         Arguments          : -NoProfile -ExecutionPolicy Bypass -File
                               "C:\Scripts\Maintenance\Nettoyage-Windows11-v5_2.ps1"
                               -Silent
         Executer avec les autorisations maximales : oui (necessaire pour
                               les droits administrateur)

  5. Superviser via le code de sortie ($LASTEXITCODE) plutot que le parsing
     du transcript : un code 1 ou 2 justifie une verification manuelle ou
     une alerte dans l'outil de supervision.

  6. Le CSV d'historique (Historique_v5.csv) et la baseline JSON
     (Baseline_v5.json) sont propres a chaque machine (stockes localement
     dans le profil de l'utilisateur qui execute le script) : aucune
     donnee n'est centralisee automatiquement. Une remontee centralisee
     (partage reseau, collecte des JSON) reste a mettre en place
     separement si necessaire pour une vision multi-machines consolidee.


================================================================================
10. DEPANNAGE RAPIDE
================================================================================

  Une cible apparait en rouge (!) ou jaune (~) dans le rapport
      -> Des fichiers etaient ouverts par une application au moment du
         nettoyage (ex : navigateur en cours d'execution pendant le
         nettoyage de son cache). Fermer l'application concernee et
         relancer le script pour finir le nettoyage de cette cible.
         Le resume de fin de run liste les cibles concernees avec le
         volume exact non recupere.

  "-OnlyTargets" ou "-SkipTargets" semble ne rien faire
      -> Verifier l'orthographe exacte du nom de cible (voir section 2 ou
         les noms affiches dans la console lors d'un run normal). Le
         script affiche desormais un avertissement explicite en fin de
         run si un nom fourni ne correspond a aucune cible reelle.

  -SelfTest indique un FAIL
      -> Lire le libelle du test en echec : il correspond generalement a
         un prerequis systeme manquant (droits admin, service Windows
         arrete, robocopy/DISM absent d'un environnement restreint,
         dossier rapports non inscriptible). Corriger le prerequis puis
         relancer -SelfTest.

  Le point de restauration echoue systematiquement
      -> Comportement normal de Windows si un point a deja ete cree dans
         les dernieres 24h pour le type MODIFY_SETTINGS (throttle
         Windows, pas un bug du script).

  Le gain disque mesure est proche de 0 alors que des elements ont ete
  supprimes
      -> Normal : Windows peut reoccuper l'espace libere quasi
         instantanement (cache disque, fichiers systeme temporaires
         generes en parallele). Se referer plutot a la colonne "Gain"
         par cible dans le rapport HTML, qui mesure precisement l'espace
         libere pour chaque dossier nettoye.

================================================================================
