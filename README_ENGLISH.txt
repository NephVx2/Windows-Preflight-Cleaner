================================================================================
  Nettoyage-Windows11 v5.2 - README
  Windows 11 maintenance and cleanup suite
================================================================================

TABLE OF CONTENTS
------------------
 1. Overview
 2. What the script cleans (full detail)
 3. What the script does NOT touch
 4. Prerequisites
 5. First run (step by step)
 6. Available parameters
 7. Exit codes (monitoring / scheduled tasks)
 8. Generated reports
 9. Multi-machine deployment
10. Quick troubleshooting


================================================================================
 1. OVERVIEW
================================================================================

Nettoyage-Windows11 is a standalone PowerShell script that cleans system and
application caches, obsolete logs, multi-user temporary files, and Windows
components (WinSxS via DISM) on a Windows 11 machine.

On every run, it:
  - processes 46 fixed cleanup targets, grouped into categories (plus
    dynamic targets: detected LibreWolf profiles, other Windows accounts
    present on the machine);
  - flushes the DNS cache and empties the Recycle Bin;
  - runs a Windows component cleanup via DISM (StartComponentCleanup,
    with an optional /ResetBase);
  - generates an HTML report (dark dashboard theme), a full JSON export,
    a CSV history export, and a JSON baseline used to compute a delta
    against the previous run;
  - automatically purges old reports past a configurable retention period.

The script is designed to run both interactively (workstation) and silently
(scheduled task, multi-machine deployment).


================================================================================
 2. WHAT THE SCRIPT CLEANS (FULL DETAIL)
================================================================================

Windows Update
  - Windows Update ........... C:\Windows\SoftwareDistribution\Download
    (the wuauserv service is stopped for the duration of the cleanup, then
    restarted)

Temporary files and system caches
  - User Temp ................. %TEMP%
  - Windows Temp .............. C:\Windows\Temp
  - DirectX Cache ............. %LOCALAPPDATA%\D3DSCache
  - Delivery Optimization ..... C:\Windows\SoftwareDistribution\DeliveryOptimization
  - Explorer Thumbnails ........ %LOCALAPPDATA%\Microsoft\Windows\Explorer
  - WER ReportArchive .......... C:\ProgramData\Microsoft\Windows\WER\ReportArchive
  - WER ReportQueue ............ C:\ProgramData\Microsoft\Windows\WER\ReportQueue
  - WER Temp .................... C:\Windows\WER\Temp (per-user, under %LOCALAPPDATA%)
  - CrashDumps ................... %LOCALAPPDATA%\CrashDumps

Logs
  - WindowsUpdate Logs ......... C:\Windows\Logs\WindowsUpdate
  - CBS Logs .................... C:\Windows\Logs\CBS
  - DISM Logs .................... C:\Windows\Logs\DISM
  - Panther Setup Logs ........... C:\Windows\Panther

Prefetch and memory dumps
  - Prefetch ...................... C:\Windows\Prefetch
  - Memory Dumps (Minidump) ....... C:\Windows\Minidump
  - MEMORY.DMP ...................... C:\Windows\MEMORY.DMP

Unit system caches
  - IconCache.db ..................... %LOCALAPPDATA%\IconCache.db
  - FNTCACHE.DAT ....................... C:\Windows\System32\FNTCACHE.DAT
    (the FontCache service is stopped for the duration of the cleanup, then
    restarted)

Developer tools
  - npm cache ........................... %APPDATA%\npm-cache
  - pip cache ............................ %LOCALAPPDATA%\pip\Cache
  - cargo cache ........................... %USERPROFILE%\.cargo\registry\cache
  - VS Code Cache .......................... %APPDATA%\Code\Cache
  - VS Code CachedData ...................... %APPDATA%\Code\CachedData
  - VS Code Logs .............................. %APPDATA%\Code\logs
  - VS Code GPUCache ............................ %APPDATA%\Code\GPUCache

WebView2 (Chromium component independent from Edge, used by Widgets, Teams,
and various apps for embedded web rendering - cache only, regenerates
automatically, no risk)
  - WebView2 Cache ................................ %LOCALAPPDATA%\Microsoft\EdgeWebView\User Data\Default\Cache
  - WebView2 Code Cache ............................ %LOCALAPPDATA%\Microsoft\EdgeWebView\User Data\Default\Code Cache
  - WebView2 GPUCache ............................... %LOCALAPPDATA%\Microsoft\EdgeWebView\User Data\Default\GPUCache

Recent access history (Start Menu / Taskbar JumpLists - purely
cosmetic/privacy-related, automatically rebuilt through normal use)
  - Automatic JumpLists .............................. %APPDATA%\Microsoft\Windows\Recent\AutomaticDestinations
  - Manual JumpLists ................................... %APPDATA%\Microsoft\Windows\Recent\CustomDestinations

NVIDIA
  - NVIDIA DXCache ....................................... %LOCALAPPDATA%\NVIDIA\DXCache
  - NVIDIA GLCache ........................................ %LOCALAPPDATA%\NVIDIA\GLCache
  - NVIDIA OptixCache ....................................... %LOCALAPPDATA%\NVIDIA\OptixCache

Spotify
  - Spotify Storage Cache .................................... %LOCALAPPDATA%\Spotify\Storage
  - Spotify Data Cache ......................................... %LOCALAPPDATA%\Spotify\Data

Steam (only processed if Steam is detected via the registry key
HKCU:\Software\Valve\Steam - cleanly skipped otherwise)
  - Steam AppCache .............................................. <Steam folder>\appcache
  - Steam HtmlCache ............................................... <Steam folder>\htmlcache
  - Steam incomplete downloads ..................................... <Steam folder>\steamapps\downloading

Browsers
  - Brave Cache ..................................................... %LOCALAPPDATA%\BraveSoftware\Brave-Browser\User Data\Default\Cache
  - Brave Code Cache ................................................. %LOCALAPPDATA%\BraveSoftware\Brave-Browser\User Data\Default\Code Cache
  - Brave GPU Cache .................................................... %LOCALAPPDATA%\BraveSoftware\Brave-Browser\User Data\Default\GPUCache
  - LibreWolf Cache [profile] ........................................... one Cache/StartupCache pair
  - LibreWolf StartupCache [profile] ..................................... generated per LibreWolf profile
                                                                            automatically detected on the
                                                                            machine (0, 1, or several)

Multi-user temp profiles (v5 addition - dynamic target)
  - Temp [account_name] .................................................. C:\Users\<account>\AppData\Local\Temp
                                                                            for every Windows account present
                                                                            on the machine other than the
                                                                            current user

Non-target actions (run on every execution, except in -DryRun mode)
  - DNS Cache ............................................................. ipconfig /flushdns
  - Recycle Bin ............................................................ full purge (all drives)
  - System Restore Point (optional, -CreateRestorePoint) - subject to
    Windows' 1-checkpoint-per-24h throttle for the MODIFY_SETTINGS type
  - DISM StartComponentCleanup ............................................ cleans up old versions of
                                                                            Windows components (WinSxS).
                                                                            With -ResetBase (separate
                                                                            option, requires interactive
                                                                            confirmation): PERMANENTLY
                                                                            removes old component
                                                                            versions - no update rollback
                                                                            possible afterwards.


================================================================================
 3. WHAT THE SCRIPT DOES NOT TOUCH
================================================================================

  - No documents, photos, projects, or user files: only caches, logs, and
    temporary files that are automatically regenerated by Windows or the
    relevant applications.
  - No browser data other than the cache (browsing history, saved
    passwords, bookmarks, cookies, open sessions: all left untouched).
  - The Windows registry is never modified.
  - An internal safety guard (Test-SafeCleanupPath) automatically rejects
    any target located fewer than 2 levels below a drive root (C:\,
    C:\Windows, C:\Users...), to protect against a future configuration
    mistake that could point the cleanup at a system folder that's too
    broad.


================================================================================
 4. PREREQUISITES
================================================================================

  - Windows 11 (also works on Windows 10, not the primary target for
    testing).
  - PowerShell 5.1 (built into Windows) or PowerShell 7+.
  - Administrator rights. The script self-elevates if launched from a
    non-admin session (UAC prompt).
  - robocopy.exe and DISM.exe present (built into Windows by default).
  - The reports folder must be writable:
    %USERPROFILE%\Desktop\Rapports_Maintenance\Nettoyage systeme
    (automatically created on first run if missing).
  - If the script is digitally signed (recommended in environments using
    -ExecutionPolicy AllSigned/RemoteSigned): the signing certificate must
    be trusted on the target machine, otherwise PowerShell will refuse to
    run it.


================================================================================
 5. FIRST RUN (STEP BY STEP)
================================================================================

  1. Copy Nettoyage-Windows11-v5_2.ps1 to the target machine (for example
     into a C:\Scripts\Maintenance folder).

  2. Open a PowerShell terminal (no need to run it as admin manually, the
     script self-elevates).

  3. Check system prerequisites WITHOUT cleaning anything:

         .\Nettoyage-Windows11-v5_2.ps1 -SelfTest

     This runs 17 automated checks (admin rights, presence of
     robocopy/DISM, required services, internal script functions) and
     displays PASS/FAIL for each one. The script then exits without
     touching any files.

     Expected exit code: 0 (see section 7 for details).

  4. Run a full simulation BEFORE the first real cleanup, to preview what
     would be removed without removing anything:

         .\Nettoyage-Windows11-v5_2.ps1 -DryRun

     This calculates potential gains per target, generates an HTML report
     flagged "[SIMULATION MODE]", and performs no deletion, no DISM run,
     and no DNS/Recycle Bin flush.

  5. Read the generated HTML report (the script offers to open it
     automatically, unless -Silent is used) to confirm the targets and
     estimated volumes make sense on this particular machine.

  6. Run the first real cleanup:

         .\Nettoyage-Windows11-v5_2.ps1

     Answer the interactive prompts (open report, final ENTER
     confirmation). The full cleanup typically takes under 10 seconds
     excluding DISM (DISM StartComponentCleanup can take several minutes
     depending on the state of the WinSxS folder).

  7. (Optional, for automated deployment) once the behavior has been
     validated manually, schedule the run via Windows Task Scheduler with
     the -Silent parameter (see section 9).


================================================================================
 6. AVAILABLE PARAMETERS
================================================================================

  -Silent
      Suppresses interactive prompts (-ResetBase confirmation, final ENTER
      pause) and does not automatically open the HTML report.
      Use this consistently for any scheduled task.

  -DryRun
      Simulation mode: calculates potential gains without deleting
      anything, without running DISM, and without flushing the DNS cache
      or emptying the Recycle Bin.

  -SelfTest
      Checks prerequisites (admin rights, robocopy, DISM, services,
      writable reports folder) and 10 internal script functions
      (formatting, safety guard, file lock detection, JSON/CSV
      round-trip, LibreWolf/Steam detection), then exits without
      cleaning. 17 checks in total.

  -CreateRestorePoint
      Creates a system restore point before the DISM cleanup. Subject to
      Windows' 1-checkpoint-per-24h throttle for the MODIFY_SETTINGS type
      (may fail silently if a checkpoint was already created recently by
      another process - this is normal Windows behavior, not a script
      bug).

  -ResetBase
      Adds /ResetBase to the DISM cleanup: PERMANENTLY removes old
      versions of WinSxS components. No update rollback possible
      afterwards. Requires explicit interactive confirmation, unless
      -Silent is used (in which case the operation runs without
      confirmation - only use this combination in silent/automated mode
      with full awareness of the consequences).

  -SkipTargets "Name1","Name2"
      List of target names to skip (use the exact names shown in the
      console during a normal run, e.g. "npm cache"). If a provided name
      does not match any real target during the run (typo), an explicit
      warning is shown at the end of execution.

  -OnlyTargets "Name1","Name2"
      List of target names to process exclusively (all others are
      skipped). Same typo detection as -SkipTargets.

  -RetainReportsDays <number>
      Number of days HTML/JSON/Transcript reports are retained before
      automatic purge at the end of the run (default: 60). The CSV
      history and the JSON baseline are never purged. Use
      -RetainReportsDays 0 to disable the purge.

  Examples:

      .\Nettoyage-Windows11-v5_2.ps1 -DryRun
      .\Nettoyage-Windows11-v5_2.ps1 -Silent -SkipTargets "Prefetch","Steam AppCache"
      .\Nettoyage-Windows11-v5_2.ps1 -CreateRestorePoint -ResetBase
      .\Nettoyage-Windows11-v5_2.ps1 -RetainReportsDays 30


================================================================================
 7. EXIT CODES (MONITORING / SCHEDULED TASKS)
================================================================================

  Useful for integrating the script into multi-machine monitoring without
  having to parse the text transcript.

      0 = full run completed, nothing to report
      1 = run completed but locked/protected targets were detected
          (files in use at the time of cleanup), or -SelfTest failed
      2 = unhandled fatal error (caught by a global safety net that
          displays the error message before exiting)

  Check after a run: $LASTEXITCODE (PowerShell)


================================================================================
 8. GENERATED REPORTS
================================================================================

  On every run (including -DryRun, and partially -SelfTest), the script
  writes the following files to:

      %USERPROFILE%\Desktop\Rapports_Maintenance\Nettoyage systeme\

      Nettoyage-YYYY-MM-DD_HH-mm-ss.html   Visual report (dark dashboard:
                                            summary tiles, disk usage bar,
                                            10-run trend, per-target detail
                                            with color-coded status, action
                                            log)
      Nettoyage-YYYY-MM-DD_HH-mm-ss.json   Full export of all run data
      Transcript-YYYY-MM-DD_HH-mm-ss.log   Raw PowerShell transcript
      Historique_v5.csv                    Cumulative history (append-only),
                                            never purged
      Baseline_v5.json                     State of the last run, used to
                                            compute the delta on the next
                                            run, never purged

  HTML/JSON/Transcript reports older than -RetainReportsDays (60 days by
  default) are automatically purged at the end of the run.

  In the HTML report, each target displays a status badge:
      [check]  green    Cleaned
      [~]      yellow   Partially cleaned (partly locked/protected)
      [!]      red      Locked or protected (nothing could be removed)
      [-]      gray     Already empty
      [~=]     yellow   Simulation (-DryRun only)


================================================================================
 9. MULTI-MACHINE DEPLOYMENT
================================================================================

  The script is designed as a self-contained file (no external
  dependencies other than robocopy.exe and DISM.exe, both built into
  Windows). For a multi-machine rollout:

  1. Distribute the .ps1 file (network copy, GPO, deployment tool, or a
     clone of the Git repository) to a local folder on each machine.

  2. If a strict execution policy is enforced (-ExecutionPolicy AllSigned
     or RemoteSigned), make sure the script's signing certificate is
     trusted on each target machine (either the "Trusted Root
     Certification Authorities" or "Trusted Publishers" store, depending
     on the policy in place); otherwise PowerShell will refuse to run it.

  3. On each machine, run -SelfTest first to validate prerequisites
     before any real cleanup (see section 5, step 3). The exit code
     (section 7) makes it easy to automate this check.

  4. Schedule execution via Windows Task Scheduler (or your enterprise
     equivalent), with the -Silent parameter mandatory to avoid getting
     stuck on an interactive prompt:

         Program/script     : pwsh.exe (or powershell.exe)
         Arguments          : -NoProfile -ExecutionPolicy Bypass -File
                               "C:\Scripts\Maintenance\Nettoyage-Windows11-v5_2.ps1"
                               -Silent
         Run with highest privileges : yes (required for administrator
                               rights)

  5. Monitor via the exit code ($LASTEXITCODE) rather than by parsing the
     transcript: a code of 1 or 2 warrants a manual check or an alert in
     your monitoring tool.

  6. The CSV history (Historique_v5.csv) and the JSON baseline
     (Baseline_v5.json) are local to each machine (stored in the profile
     of the user running the script): no data is centralized
     automatically. A centralized rollup (network share, JSON collection)
     is left to be implemented separately if a consolidated
     multi-machine view is needed.


================================================================================
10. QUICK TROUBLESHOOTING
================================================================================

  A target shows up red (!) or yellow (~) in the report
      -> Some files were open in an application at the time of cleanup
         (e.g. a browser running while its cache was being cleaned).
         Close the relevant application and re-run the script to finish
         cleaning that target. The end-of-run summary lists the affected
         targets along with the exact amount of space that could not be
         recovered.

  "-OnlyTargets" or "-SkipTargets" seems to do nothing
      -> Double-check the exact target name spelling (see section 2, or
         the names shown in the console during a normal run). The script
         now displays an explicit warning at the end of the run if a
         provided name does not match any real target.

  -SelfTest reports a FAIL
      -> Read the label of the failing test: it generally points to a
         missing system prerequisite (admin rights, a stopped Windows
         service, robocopy/DISM missing from a restricted environment,
         a non-writable reports folder). Fix the prerequisite, then
         re-run -SelfTest.

  The system restore point consistently fails
      -> Normal Windows behavior if a checkpoint was already created
         within the last 24 hours for the MODIFY_SETTINGS type (Windows
         throttling, not a script bug).

  The measured disk gain is close to 0 even though items were deleted
      -> Normal: Windows can reclaim freed space almost instantly for its
         own purposes (disk cache, temporary system files generated in
         parallel). Refer instead to the per-target "Gain" column in the
         HTML report, which precisely measures the space freed for each
         cleaned folder.

================================================================================
