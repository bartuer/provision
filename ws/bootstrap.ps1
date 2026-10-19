<#
.SYNOPSIS
    bootstrap.ps1 -- plan 01 G.1: a Windows box with nothing -> WSL2 distro + Git/GCM -> init.sh (clone
    /workspace + ./install.sh).  PowerShell 5.1, no modules.  REAL RUN BY DEFAULT; -DryRun (or $env:WS_DRY=1) changes nothing, prints
    what it would do.

.DESCRIPTION
    Each step prints KEY=ok|WOULD <action>|FAIL <why>; the last line is RESULT=OK|PLAN|FAIL|REBOOT_NEEDED|
    RESTART_NEEDED|REFUSED.
      ADMIN   elevated?  (a real run needs it for WSL / DISTRO installs)
      WSL     Ubuntu-26.04 on WSL2: absent -> `wsl --install -d Ubuntu-26.04 --no-launch` (engine + distro in one
              step, live progress; no reboot)
      GIT     git.exe; absent -> Git for Windows from its GitHub release (winget only as fallback)
      GCM     `git credential-manager --version`; absent -> comes with Git, else the GCM GitHub release
      INIT    init.sh (next to this file, else -InitUrl) run as root in the distro: dry-run -> its own dry
              run is shown as `  init: ...` lines; real run -> `init.sh --apply`.  On failure the one-liner to
              re-run is this same bootstrap (everything is idempotent).
    A distro restart (init.sh says RESTART_NEEDED: systemd was just enabled) is a separate gate
    done here automatically with `wsl --terminate <distro>` -- never `wsl --shutdown`.  It is refused (the
    command is printed for the user instead) when this script runs from inside WSL or when the distro has
    running containers or tmux sessions.

.EXAMPLE
    irm tinyurl.com/ws-bootstrap | iex                          # real run
    $env:WS_DRY=1; irm tinyurl.com/ws-bootstrap | iex           # dry run (changes nothing)
    $env:WS_ALLOW_RESTART=1; ...                                # also allow one `wsl --terminate`; WS_DISTRO=<name>
    powershell -ExecutionPolicy Bypass -File bootstrap.ps1 [-DryRun] [-AllowRestart]
#>
[CmdletBinding()]
param(
    [switch] $DryRun       = ($env:WS_DRY -eq '1'),             # env twins: `irm | iex` cannot pass parameters
    [switch] $Apply,                                            # accepted for old command lines; the real run is the default
    [switch] $AllowRestart = ($env:WS_ALLOW_RESTART -eq '1'),
    [string] $Distro  = "$env:WS_DISTRO",
    [string] $WsUrl   = 'https://dev.azure.com/MSRADKI/Excel/_git/workspace',
    [string] $InitUrl = '',
    [string] $User    = "$env:WS_USER"                          # WSL login user; default = the Windows user name
)
$ErrorActionPreference = 'Stop'
$Apply = -not $DryRun
Remove-Item Env:WS_DRY, Env:WS_ALLOW_RESTART, Env:WS_DISTRO, Env:WS_USER -ErrorAction SilentlyContinue   # one-shot: a dry run must not stick to the next plain line
$env:WSL_UTF8 = '1'                       # wsl.exe management output in UTF-8 (older WSL: UTF-16, NULs stripped below)
$DefaultInitUrl = 'https://raw.githubusercontent.com/bartuer/provision/main/ws/init.sh'                      # set by bin/gist-publish.sh to the gist raw init.sh URL (G.4)
$NewDistro      = 'Ubuntu-26.04'            # the fleet release (wsl --list --online name)
$WantVersion    = '26.04'                   # VERSION_ID the distro must report
$script:fail = 0; $script:result = ''
function Emit($k, $v) { Write-Output "$k=$v"; if ("$v" -like 'FAIL*') { $script:fail++ } }
function Done($r) { if ($r) { $script:result = $r }; if (-not $script:result) { $script:result = $(if ($script:fail) { 'FAIL' } elseif (-not $Apply) { 'PLAN' } else { 'OK' }) }
                    Write-Output "RESULT=$($script:result)"; $script:exitCode = $(if ($script:result -in @('FAIL','REFUSED')) { 1 } else { 0 }) }
function Q([string]$x) { if ($x -eq '' -or $x -match '[\s"]') { '"' + ($x -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"' } else { $x } }
function Native([string]$exe, [string[]]$a, [int]$Timeout = 120, [string]$Tag = '') {
    # run a native exe LIVE: every line is shown as it arrives (`  <tag>: ...`, \r progress redrawn in place),
    # a heartbeat every 15s of silence, killed after $Timeout s (rc 1460).  stdin is CLOSED, so a "press any key"
    # prompt (the inbox wsl.exe stub on a box without WSL) gets EOF instead of hanging forever.
    # Returns the \n-terminated lines (NULs stripped); $script:rc = exit code.
    if (-not $Tag) { $Tag = [IO.Path]::GetFileNameWithoutExtension($exe) }
    $cmdline = "$exe $($a -join ' ')"
    $out = New-Object System.Collections.Generic.List[string]
    $path = (Get-Command $exe -ErrorAction SilentlyContinue | Select-Object -First 1).Source
    if (-not $path) { $script:rc = 9009; Write-Host "  ${Tag}: not found: $exe"; return @() }
    $psi = New-Object Diagnostics.ProcessStartInfo $path
    $psi.Arguments = ($a | ForEach-Object { Q $_ }) -join ' '
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.RedirectStandardInput = $true
    try { $p = [Diagnostics.Process]::Start($psi) } catch { $script:rc = 9009; Write-Host "  ${Tag}: start failed: $_"; return @() }
    try { $p.StandardInput.Close() } catch {}
    $rd = @(@{ s = $p.StandardOutput; b = New-Object char[] 4096; t = $null; acc = ''; done = $false },
            @{ s = $p.StandardError;  b = New-Object char[] 4096; t = $null; acc = ''; done = $false })
    $sw = [Diagnostics.Stopwatch]::StartNew(); $last = 0; $cr = $false
    $show = { param($l, $isCr)
        $l = ($l -replace "`0", '').TrimEnd()
        if ($l -eq '') { return }
        if ($isCr) { Write-Host -NoNewline ("`r  ${Tag}: " + $l + '   '); $script:crOpen = $true }
        else { if ($script:crOpen) { Write-Host '' ; $script:crOpen = $false }; Write-Host "  ${Tag}: $l"; $out.Add($l) } }
    $script:crOpen = $false
    while ($true) {
        $busy = $false
        foreach ($r in $rd) {
            if ($r.done) { continue }
            if (-not $r.t) { $r.t = $r.s.ReadAsync($r.b, 0, $r.b.Length) }
            if ($r.t.IsCompleted) {
                $busy = $true; $n = $r.t.Result; $r.t = $null
                if ($n -le 0) { $r.done = $true; if ($r.acc) { & $show $r.acc $false; $r.acc = '' }; continue }
                $r.acc += (New-Object string ($r.b, 0, $n))
                while ($r.acc -match '^([^\r\n]*)([\r\n])') {
                    $seg = $Matches[1]; $sep = $Matches[2]; $r.acc = $r.acc.Substring($seg.Length + 1)
                    if ($sep -eq "`r" -and $r.acc.StartsWith("`n")) { $r.acc = $r.acc.Substring(1); $sep = "`n" }
                    & $show $seg ($sep -eq "`r")
                }
                $last = $sw.Elapsed.TotalSeconds
            }
        }
        if ($rd[0].done -and $rd[1].done) { break }
        $t = $sw.Elapsed.TotalSeconds
        if ($t -gt $Timeout) {
            try { $p.Kill() } catch {}
            if ($script:crOpen) { Write-Host ''; $script:crOpen = $false }
            Write-Host "  ${Tag}: TIMEOUT after $([int]$t)s -- killed: $cmdline"; $script:rc = 1460; return @($out)
        }
        if ($t - $last -ge 15) { if ($script:crOpen) { Write-Host ''; $script:crOpen = $false }
                                 Write-Host "  ${Tag}: ... still running $([int]$t)s (timeout ${Timeout}s): $cmdline"; $last = $t }
        if (-not $busy) { Start-Sleep -Milliseconds 100 }
        if ($t -ge 2) { Write-Progress -Activity "${Tag}: $cmdline" -Status ("{0}s elapsed (timeout {1}s)" -f [int]$t, $Timeout) -PercentComplete ([math]::Min(99, [int](100 * $t / $Timeout))) }
    }
    if ($script:crOpen) { Write-Host ''; $script:crOpen = $false }
    $p.WaitForExit(); $script:rc = $p.ExitCode
    Write-Progress -Activity "${Tag}: $cmdline" -Completed
    return @($out)
}
function Step([string]$m) { Write-Host "-- $m" }
function Live([string]$exe, [string[]]$a, [int]$Timeout = 1800, [string]$What = '') {
    # run a long native step ON THIS CONSOLE (not redirected), so wsl.exe / winget draw their own % progress bar;
    # on top, a PowerShell progress bar shows the step and its elapsed time.  Killed after $Timeout s (rc 1460).
    if (-not $What) { $What = "$exe $($a -join ' ')" }
    $path = (Get-Command $exe -ErrorAction SilentlyContinue | Select-Object -First 1).Source
    if (-not $path) { $script:rc = 9009; Write-Host "  not found: $exe"; return }
    try { $p = Start-Process -FilePath $path -ArgumentList (($a | ForEach-Object { Q $_ }) -join ' ') -NoNewWindow -PassThru }
    catch { $script:rc = 9009; Write-Host "  start failed: $_"; return }
    $null = $p.Handle   # PS 5.1: without touching Handle, ExitCode reads $null after exit
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while (-not $p.WaitForExit(1000)) {
        $t = [int]$sw.Elapsed.TotalSeconds
        Write-Progress -Activity $What -Status ("{0}m{1:d2}s elapsed (timeout {2}m)" -f [int][math]::Floor($t / 60), ($t % 60), [int]($Timeout / 60)) -PercentComplete ([math]::Min(99, [int](100 * $t / $Timeout)))
        if ($t -gt $Timeout) { try { $p.Kill() } catch {}; Write-Progress -Activity $What -Completed
                               Write-Host "  TIMEOUT after ${t}s -- killed: $What"; $script:rc = 1460; return }
    }
    $p.WaitForExit(); Write-Progress -Activity $What -Completed
    $script:rc = $p.ExitCode
    Write-Host ("  {0}: rc={1} in {2}s" -f $What, $script:rc, [int]$sw.Elapsed.TotalSeconds)
}
function InWsl {   # this PowerShell started from a WSL shell (interop)?  then terminating the distro kills us
    if ($env:WSL_DISTRO_NAME) { return $true }
    $id = $PID
    for ($i = 0; $i -lt 8; $i++) {
        $p = Get-CimInstance Win32_Process -Filter "ProcessId=$id" -ErrorAction SilentlyContinue
        if (-not $p) { break }
        if ($p.Name -in @('wslhost.exe','wsl.exe','wslrelay.exe','bash.exe')) { return $true }
        $id = $p.ParentProcessId
    }
    return $false
}
function RefreshPath { $env:Path = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' + [Environment]::GetEnvironmentVariable('Path','User') }
function Distros {   # @{name=..; ver=..; default=$bool} from `wsl -l -v`
    $r = @()
    foreach ($l in (Native 'wsl.exe' @('-l','-v'))) {
        if ($l -match '^\s*(\*)?\s*(\S+)\s+(Running|Stopped|Installing|Converting|Uninstalling)\s+(\d)\s*$') {
            $r += [pscustomobject]@{ name = $Matches[2]; ver = [int]$Matches[4]; default = [bool]$Matches[1] }
        }
    }
    return $r
}
function InDistro([string]$cmd) { return Native 'wsl.exe' @('-d', $script:D, '-u', 'root', '-e', 'sh', '-c', $cmd) }

function Main {
Write-Output "MODE=$(if ($Apply) { 'apply' } else { 'dry-run' })"

# ADMIN
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
           ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
Emit 'ADMIN' $(if ($isAdmin) { 'ok' } else { 'NO (installs of WSL / a distro need an elevated PowerShell)' })

# WSL -- one step, one target: Ubuntu-26.04 on WSL2.  `wsl --install -d Ubuntu-26.04 --no-launch` installs the WSL
# engine, the Windows features (VirtualMachinePlatform) and the distro, as WSL2 (the default).  A first install
# asks for a Windows reboot: say so and stop; the re-run after the reboot finds it and moves on.
$script:D = $(if ($Distro) { $Distro } else { $NewDistro })
function HaveDistro { [bool](Distros | Where-Object { $_.name -eq $script:D }) }
function DistroVer { Step "WSL: start $($script:D) (first start can take a minute)"
    (Native 'wsl.exe' @('-d', $script:D, '-u', 'root', '-e', 'sh', '-c', '. /etc/os-release; echo $ID $VERSION_ID') -Timeout 300 | Select-Object -Last 1) }
$haveWsl = [bool](Get-Command wsl.exe -ErrorAction SilentlyContinue)
Step "WSL: is $($script:D) installed? (wsl -l -v)"
$have = $haveWsl -and (HaveDistro)
if ($haveWsl -and -not $have -and -not $Distro) {   # an existing default distro that IS ubuntu 26.04 (e.g. named `Ubuntu`): use it
    $dd = Distros | Where-Object { $_.default -and $_.name -notlike 'docker-desktop*' } | Select-Object -First 1
    if ($dd) { $keep = $script:D; $script:D = $dd.name
               if ((DistroVer) -eq "ubuntu $WantVersion") { $have = $true } else { $script:D = $keep } }
}
if (-not $have) {
    if (-not $Apply) { Emit 'WSL' "WOULD wsl --install -d $($script:D) --no-launch (WSL2; then maybe a Windows reboot)"; return (Done) }
    if (-not $isAdmin) { Emit 'WSL' 'FAIL not admin: re-run from an elevated PowerShell'; return (Done) }
    Step "WSL: wsl --install -d $($script:D) --no-launch --web-download (WSL engine + distro, WSL2; wsl's own progress below)"
    Live 'wsl.exe' @('--install', '-d', $script:D, '--no-launch', '--web-download') -What "wsl --install -d $($script:D)"
    if (-not (HaveDistro)) { Emit 'WSL' "FAIL $($script:D) not registered after wsl --install (rc=$($script:rc)) -- if wsl asked for a Windows reboot, reboot and run this again"; return (Done) }
    Emit 'WSL' "did wsl --install -d $($script:D) --no-launch --web-download"
}
$d = Distros | Where-Object { $_.name -eq $script:D } | Select-Object -First 1
if ($d.ver -ne 2) {
    if (-not $Apply) { Emit 'WSL' "WOULD wsl --set-version $($script:D) 2"; return (Done) }
    Step "WSL: wsl --set-version $($script:D) 2"
    Live 'wsl.exe' @('--set-version', $script:D, '2') -What "wsl --set-version $($script:D) 2"
    if ($script:rc -ne 0) { Emit 'WSL' "FAIL wsl --set-version $($script:D) 2 rc=$($script:rc)"; return (Done) }
}
$v = DistroVer
if ($v -eq "ubuntu $WantVersion") { Emit 'WSL' "ok $($script:D) WSL2 ($v)" }
else { Emit 'WSL' "FAIL $($script:D) reports '$v', the fleet needs ubuntu $WantVersion (rc=$($script:rc))"; return (Done) }

# GIT + GCM -- straight from the GitHub releases (Invoke-RestMethod/BITS use the Windows cert store, so a
# TLS-inspecting corporate proxy is trusted).  winget is only the FALLBACK: on a devbox it fails twice --
# msstore "No packages were found" and "The server certificate did not match any of the expected values"
# (winget pins its CDN certificate, the proxy re-signs it).
function HaveGit { RefreshPath; [bool](Get-Command git.exe -ErrorAction SilentlyContinue) }
function HaveGcm { if (-not (HaveGit)) { return $false }; Native 'git.exe' @('credential-manager', '--version') | Out-Null; return ($script:rc -eq 0) }
function GhInstall([string]$repo, [string]$pattern, [string[]]$args2, [string]$what, [string]$pin = '') {
    # $pin (a fixed release asset URL, the version proven on c17) first; else the latest release asset of
    # github.com/$repo matching $pattern -> %TEMP% (BITS progress bar) -> run silent (Live)
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}
    $u = $null; $name = $null
    if ($pin) { $u = $pin; $name = ($pin -split '/')[-1]; Step "${what}: pinned $name" }
    else { Step "${what}: latest release of github.com/$repo" }
    if (-not $u) { try {
        $rel = Invoke-RestMethod -UseBasicParsing "https://api.github.com/repos/$repo/releases/latest"
        $as = $rel.assets | Where-Object { $_.name -match $pattern } | Select-Object -First 1
        if ($as) { $u = $as.browser_download_url; $name = $as.name }
    } catch { Write-Host "  ${what}: api.github.com failed ($($_.Exception.Message)); trying the release page" } }
    if (-not $u) {   # api rate limit / blocked: scrape the expanded-assets page of the latest tag
        try {
            $r = Invoke-WebRequest -UseBasicParsing "https://github.com/$repo/releases/latest" -MaximumRedirection 5
            $tag = ($r.BaseResponse.ResponseUri.AbsoluteUri -split '/tag/')[-1]
            $page = (Invoke-WebRequest -UseBasicParsing "https://github.com/$repo/releases/expanded_assets/$tag").Content
            $m = [regex]::Matches($page, 'href="(/' + [regex]::Escape($repo) + '/releases/download/[^"]+)"') | ForEach-Object { $_.Groups[1].Value } |
                 Where-Object { ($_ -split '/')[-1] -match $pattern } | Select-Object -First 1
            if ($m) { $u = "https://github.com$m"; $name = ($m -split '/')[-1] }
        } catch { Write-Host "  ${what}: release page failed ($($_.Exception.Message))" }
    }
    if (-not $u) { Write-Host "  ${what}: no installer matching $pattern found"; $script:rc = 2; return }
    $exe = Join-Path $env:TEMP $name
    Step "${what}: download $name"
    try { Start-BitsTransfer -Source $u -Destination $exe -DisplayName "download $name" -ErrorAction Stop }
    catch { Write-Host "  ${what}: BITS failed ($($_.Exception.Message)), plain download"
            try { $ProgressPreference = 'Continue'; Invoke-WebRequest -UseBasicParsing $u -OutFile $exe } catch { Write-Host "  ${what}: download failed: $($_.Exception.Message)"; $script:rc = 3; return } }
    Step "${what}: $name (silent install)"
    Live $exe $args2 -What "install $name" -Timeout 1200
    Remove-Item $exe -ErrorAction SilentlyContinue
}
function WingetInstall([string]$id, [string]$what) {
    if (-not (Get-Command winget.exe -ErrorAction SilentlyContinue)) { return }
    Step "${what}: fallback winget install $id --source winget"
    Live 'winget.exe' -a @('install', '-e', '--id', $id, '--source', 'winget', '--silent', '--accept-package-agreements', '--accept-source-agreements') -Timeout 900
}
# Pinned to what works on c17 (Git for Windows 2.55.0.5 bundles GCM 2.9.1): same build on every devbox, fixed
# GCM path C:\Program Files\Git\mingw64\bin\git-credential-manager.exe.  Latest release / winget only as fallbacks.
$GitPin = 'https://github.com/git-for-windows/git/releases/download/v2.55.0.windows.5/Git-2.55.0.5-64-bit.exe'
$GitDir = "$env:ProgramFiles\Git"
$inno = @('/VERYSILENT', '/NORESTART', '/NOCANCEL', '/SP-', '/SUPPRESSMSGBOXES')
if (HaveGit) { Emit 'GIT' 'ok' }
elseif (-not $Apply) { Emit 'GIT' 'WOULD install Git for Windows 2.55.0.5 (pinned; bundles GCM) into $GitDir' }
else {
    GhInstall 'git-for-windows/git' '' ($inno + @("/DIR=$GitDir")) 'GIT' $GitPin   # pinned: brings GCM at $GitDir\mingw64\bin
    if (-not (HaveGit)) { GhInstall 'git-for-windows/git' '^Git-[\d.]+-64-bit\.exe$' ($inno + @("/DIR=$GitDir")) 'GIT' }
    if (-not (HaveGit)) { WingetInstall 'Git.Git' 'GIT' }
    if (HaveGit) { Emit 'GIT' "did install Git for Windows ($((& git.exe --version) -join ''))" }
    else { Emit 'GIT' "FAIL git.exe still absent (github download and winget both failed, rc=$($script:rc)) -- log: $LogFile" }
}
function GcmExe {   # the Windows git-credential-manager.exe (WINDOWS path; init.sh converts it with wslpath)
    RefreshPath
    $c = New-Object System.Collections.Generic.List[string]
    $c.Add("$env:ProgramFiles\Git Credential Manager\git-credential-manager.exe")   # the standalone install (preferred)
    $g = (Get-Command git.exe -ErrorAction SilentlyContinue | Select-Object -First 1).Source
    if ($g) {
        try { $ep = (& $g --exec-path 2>$null | Select-Object -First 1) -replace '/', '\' } catch { $ep = '' }   # ...\mingw64\libexec\git-core
        if ($ep) { $c.Add("$ep\git-credential-manager.exe"); $c.Add((Join-Path (Split-Path (Split-Path $ep -Parent) -Parent) 'bin\git-credential-manager.exe')) }
        $root = Split-Path (Split-Path $g -Parent) -Parent   # ...\Git\cmd\git.exe -> ...\Git
        $c.Add("$root\mingw64\bin\git-credential-manager.exe"); $c.Add("$root\mingw64\libexec\git-core\git-credential-manager.exe")
    }
    $w = (Get-Command git-credential-manager.exe -ErrorAction SilentlyContinue | Select-Object -First 1).Source; if ($w) { $c.Add($w) }
    foreach ($pf in @($env:ProgramFiles, ${env:ProgramFiles(x86)}, "$env:LOCALAPPDATA\Programs", "$env:LOCALAPPDATA")) {
        if ($pf) { $c.Add("$pf\Git Credential Manager\git-credential-manager.exe"); $c.Add("$pf\Git\mingw64\bin\git-credential-manager.exe") } }
    $hit = $c | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1
    if (-not $hit) {   # last resort: search the git root, then the usual roots
        foreach ($r in @($(if ($g) { Split-Path (Split-Path $g -Parent) -Parent }), $env:ProgramFiles, ${env:ProgramFiles(x86)}, "$env:LOCALAPPDATA\Programs")) {
            if (-not $r -or -not (Test-Path $r)) { continue }
            $hit = Get-ChildItem -Path $r -Filter 'git-credential-manager*.exe' -Recurse -Depth 5 -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName
            if ($hit) { break }
        }
    }
    if (-not $hit) { Write-Host "  gcm: NOT FOUND (git.exe=$g; tried: $($c -join ' | '))"; return '' }
    return $hit
}
# GCM: always the STANDALONE installer (user ruling 2026-10-19: it is what pops the sign-in window for the
# ADO clone from WSL), pinned, into a fixed dir so init.sh gets one known path.
$GcmPin = 'https://github.com/git-ecosystem/git-credential-manager/releases/download/v2.7.3/gcm-win-x64-2.7.3.exe'
$GcmDir = "$env:ProgramFiles\Git Credential Manager"
function HaveGcmStd { Test-Path -LiteralPath "$GcmDir\git-credential-manager.exe" }
if (HaveGcmStd) { Emit 'GCM' "ok $GcmDir\git-credential-manager.exe ($((& "$GcmDir\git-credential-manager.exe" --version 2>$null) -join ''))" }
elseif (-not $Apply) { Emit 'GCM' "WOULD install standalone Git Credential Manager 2.7.3 (pinned) into $GcmDir" }
else {
    GhInstall 'git-ecosystem/git-credential-manager' '' ($inno + @("/DIR=$GcmDir")) 'GCM' $GcmPin
    if (-not (HaveGcmStd)) { GhInstall 'git-ecosystem/git-credential-manager' '^gcm-win-x64-[\d.]+\.exe$' ($inno + @("/DIR=$GcmDir")) 'GCM' }
    if (-not (HaveGcmStd)) { WingetInstall 'Git.GCM' 'GCM' }
    $x = GcmExe
    if (HaveGcmStd) { Emit 'GCM' "did install Git Credential Manager: $GcmDir\git-credential-manager.exe" }
    elseif ($x) { Emit 'GCM' "did install Git Credential Manager (not in $GcmDir): $x" }
    else { Emit 'GCM' "FAIL git-credential-manager.exe absent after install (rc=$($script:rc)) -- log: $LogFile" }
}

# INIT
$here = $(if ($PSCommandPath) { Split-Path -Parent $PSCommandPath } else { '' })
$local = $(if ($here) { Join-Path $here 'init.sh' } else { '' })
$url = $(if ($InitUrl) { $InitUrl } else { $DefaultInitUrl })
$src = ''; $init = $null
if ($local -and (Test-Path $local)) { $src = $local; $init = [IO.File]::ReadAllText($local) }
elseif ($url) { $src = $url; try { $init = (Invoke-RestMethod -UseBasicParsing $url) } catch { $init = $null } }
if (-not $User) { $User = "$env:USERNAME".ToLower() -replace '[^a-z0-9_-]', '' }
if ($User -notmatch '^[a-z][a-z0-9_-]{0,31}$') { $User = 'dev' }
$oneLiner = $(if ($url) { "curl -fsSL '$url' | WS_URL='$WsUrl' bash -s -- --apply" } else { "WS_URL='$WsUrl' bash init.sh --apply   # init.sh from the bootstrap gist" })
Step 'GCM: locate git-credential-manager.exe for WSL'
$GcmWin = GcmExe
$GitWin = (Get-Command git.exe -ErrorAction SilentlyContinue | Select-Object -First 1).Source
Write-Host "  git.exe : $(if ($GitWin) { $GitWin } else { 'NOT FOUND' })" -ForegroundColor Cyan
if ($GcmWin) { Write-Host "  gcm     : $GcmWin" -ForegroundColor Green } else { Write-Host "  gcm     : NOT FOUND (see the 'tried' list above)" -ForegroundColor Red }
function RunInit([string]$mode) {   # init.sh via base64 (no CRLF / encoding mangling), stdin left to the console
    $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($init -replace "`r`n", "`n")))
    $cmd = "echo $b64 | base64 -d > /tmp/ws-init.sh && INIT_GCM_WIN='$GcmWin' INIT_GIT_WIN='$GitWin' INIT_USER='$User' WS_URL='$WsUrl' bash /tmp/ws-init.sh $mode; rc=`$?; rm -f /tmp/ws-init.sh; exit `$rc"
    $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    if ($mode -eq '--apply') {   # long (apt, clone + ADO auth, lfs, install.sh): run in its OWN Ubuntu window = a real tty,
        # so apt / git clone / lfs draw their native progress and a credential prompt can be answered there.
        # `script` keeps the pty AND logs to /tmp/ws-init.out; this window shows a progress bar + the last log line.
        $ErrorActionPreference = $old
        $run = "rm -f /tmp/ws-init.out; echo $b64 | base64 -d > /tmp/ws-init.sh; " +
               "export INIT_GCM_WIN='$GcmWin' INIT_GIT_WIN='$GitWin' INIT_USER='$User'; if command -v script >/dev/null; then WS_URL='$WsUrl' script -qefc 'bash /tmp/ws-init.sh --apply' /tmp/ws-init.out; " +
               "else WS_URL='$WsUrl' bash /tmp/ws-init.sh --apply 2>&1 | tee /tmp/ws-init.out; fi; rc=`$?; rm -f /tmp/ws-init.sh; " +
               "if [ `$rc != 0 ]; then echo; echo 'init.sh FAILED (rc='`$rc') -- see the FAIL line above; press Enter to close'; read x; fi; exit `$rc"
        Step "INIT: init.sh --apply as root in a NEW Ubuntu window ($($script:D)) -- type the password for WSL user '$User' there, then watch apt / git clone / sign-in"
        $path = (Get-Command wsl.exe).Source
        $p = Start-Process -FilePath $path -ArgumentList ((@('-d', $script:D, '-u', 'root', '-e', 'bash', '-c', $run) | ForEach-Object { Q $_ }) -join ' ') -PassThru
        $null = $p.Handle
        $sw = [Diagnostics.Stopwatch]::StartNew(); $tail = ''
        while (-not $p.WaitForExit(5000)) {
            $t = [int]$sw.Elapsed.TotalSeconds
            $tl = & wsl.exe -d $script:D -u root -e sh -c "tail -c 4000 /tmp/ws-init.out 2>/dev/null | tr '\r' '\n' | sed 's/\x1b\[[0-9;?]*[A-Za-z]//g' | grep -v '^[[:space:]]*$' | tail -n 1" 2>$null
            if ($tl) { $tail = ("$tl" -replace "`0", '').Trim() }
            if ($tail.Length -gt 100) { $tail = $tail.Substring(0, 100) }
            Write-Progress -Activity 'init.sh --apply (in the Ubuntu window)' -Status ("{0}m{1:d2}s  {2}" -f [int][math]::Floor($t / 60), ($t % 60), $tail) -PercentComplete -1
            if ($t -gt 7200) { try { $p.Kill() } catch {}; Write-Host '  init: TIMEOUT after 2h -- killed'; break }
        }
        $p.WaitForExit(); Write-Progress -Activity 'init.sh --apply (in the Ubuntu window)' -Completed
        $script:rc = $p.ExitCode
        $script:initOut = @(& wsl.exe -d $script:D -u root -e sh -c "tr '\r' '\n' < /tmp/ws-init.out 2>/dev/null | sed 's/\x1b\[[0-9;?]*[A-Za-z]//g' | grep -E '^[A-Z_]+='" 2>$null | ForEach-Object { ("$_" -replace "`0", '').Trim() } | Where-Object { $_ })
        foreach ($l in $script:initOut) { Write-Host "  init: $l" }
        Write-Host ("  init: rc={0} in {1}s  (full log in the distro: /tmp/ws-init.out)" -f $script:rc, [int]$sw.Elapsed.TotalSeconds)
        return
    }
    Step "INIT: init.sh $mode as root in $($script:D) (live output below)"
    $script:initOut = @(& wsl.exe -d $script:D -u root -e bash -c $cmd 2>&1 | ForEach-Object { $l = "$_"; Write-Host "  init: $l"; $l }); $script:rc = $LASTEXITCODE
    $ErrorActionPreference = $old
}
if (-not $init) { Emit 'INIT' "FAIL could not download init.sh from $url -- check the network, then run this bootstrap again"; return (Done) }
$distroUp = [bool](Distros | Where-Object { $_.name -eq $script:D })
if (-not $Apply) {
    if ($distroUp) { RunInit '--dry-run' }
    Emit 'INIT' "WOULD run init.sh --apply ($src) as root in $($script:D): WS_URL=$WsUrl -> /workspace + ./install.sh"
    return (Done)
}
if (-not $distroUp) { Emit 'INIT' "FAIL distro $($script:D) not registered"; return (Done) }
RunInit '--apply'
$r = ($script:initOut | Where-Object { $_ -match '^RESULT=' } | Select-Object -Last 1) -replace '^RESULT=', ''
if ($r -eq 'RESTART_NEEDED') {
    $restartCmd = "wsl --terminate $($script:D)"
    if (InWsl) { Emit 'RESTART' "REFUSE running from inside WSL -- from a Windows PowerShell run: $restartCmd ; then run this again"; return (Done 'REFUSED') }
    $busy = @(InDistro 'command -v docker >/dev/null && docker ps -q 2>/dev/null; command -v tmux >/dev/null && tmux ls 2>/dev/null' | Where-Object { $_ -match '\S' })
    if ($busy.Count) { Emit 'RESTART' "REFUSE $($script:D) has running containers/tmux ($($busy.Count)) -- stop them, then: $restartCmd"; return (Done 'REFUSED') }
    Native 'wsl.exe' @('--terminate', $script:D) | Out-Null
    Emit 'RESTART' "did $restartCmd"
    RunInit '--apply'
    $r = ($script:initOut | Where-Object { $_ -match '^RESULT=' } | Select-Object -Last 1) -replace '^RESULT=', ''
}
Emit 'GCMPATH' "win=$(if ($GcmWin) { $GcmWin } else { 'NOT FOUND' }) git=$GitWin"
if ($r -eq 'OK') { Emit 'INIT' "ok init.sh --apply in $($script:D)" }
else {
    $why = @($script:initOut | Where-Object { $_ -match '=FAIL' }) -join '; '
    if (-not $why) { $why = "RESULT=$r rc=$($script:rc)" }
    Emit 'INIT' "FAIL $why -- fix that, then re-run this bootstrap (init.sh is idempotent: it does the git clone itself and skips what is done; log: wsl -d $($script:D) -u root cat /tmp/ws-init.out)"
}
return (Done)
}
$script:exitCode = 0
$LogFile = Join-Path $env:TEMP 'ws-bootstrap.log'
try { Start-Transcript -Path $LogFile -Append -ErrorAction Stop | Out-Null; $tr = $true } catch { $tr = $false }
Write-Host "-- log: $LogFile  (watch from another window: Get-Content -Wait '$LogFile')"
Main
if ($tr) { try { Stop-Transcript | Out-Null } catch {} }
if ($PSCommandPath) { exit $script:exitCode }   # -File: rc; irm|iex: never close the console
