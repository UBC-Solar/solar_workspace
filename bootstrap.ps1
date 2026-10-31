<#
.SYNOPSIS
    Bootstrap a UBC Solar firmware development environment (Windows 10/11).

.DESCRIPTION
    Windows counterpart of bootstrap.sh. Automates the wiki's "How to Install STM32 VS Code
    for Firmware_v4 Development" for Windows:
      1. Installs Git, Ruby (for Ceedling), make, the SEGGER J-Link software (USB driver) and
         VS Code with winget, each only if it's missing. The ARM toolchain, CMake and Ninja
         come from the STM32Cube bundles in step 5, which is what VS Code builds with.
      2. Checks for the ST-LINK USB driver (needs an ST account to download, so it's manual)
      3. Clones firmware_v4, sunlite and solar_tools next to this folder (each skipped if
         already present) and installs firmware_v4's git hooks
      4. Installs the STM32Cube, CMake Tools and Cortex-Debug VS Code extensions
      5. Installs the STM32Cube bundles pinned by firmware_v4 (.settings/bundles.store.json)
      6. Sets the user environment variable CUBE_BUNDLE_PATH for the workspace's clangd settings,
         and puts the newest SEGGER J-Link install (or the jlink-gdbserver bundle) on the user
         PATH, so JLink.exe works from a terminal and Cortex-Debug can find the GDB server
      7. Points the STM32Cube extension at your STM32CubeMX install (if found) and Cortex-Debug
         at the bundle's gdb and J-Link GDB server
      8. Verifies the toolchain by building one board into a temporary directory

    sunlink is not handled here; it has its own setup (see the README).

    Safe to re-run: every step checks whether it's already done, and nothing is deleted
    or overwritten.

    Run it from a normal (not "Run as administrator") PowerShell or cmd window:
        .\solar_workspace\bootstrap.cmd [options]
    The installers ask for admin rights themselves when they need them.

.PARAMETER Ssh
    Clone over SSH (git@github.com:...) instead of HTTPS.
.PARAMETER CubeMX
    Path to your STM32CubeMX.exe (default: auto-detect).
.PARAMETER SkipInstall
    Don't install programs with winget.
.PARAMETER SkipBundles
    Don't download the STM32Cube bundles (large download).
.PARAMETER SkipVerify
    Don't test-build firmware at the end.
.PARAMETER DryRun
    Print what would be done without changing anything.
#>
[CmdletBinding()]
param(
    [switch]$Ssh,
    [string]$CubeMX = "",
    [switch]$SkipInstall,
    [switch]$SkipBundles,
    [switch]$SkipVerify,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
$ScriptDir = $PSScriptRoot
$ParentDir = Split-Path $ScriptDir -Parent
$GithubOrg = "UBC-Solar"
$FwRepo = "firmware_v4"
$FwDir = Join-Path $ParentDir $FwRepo
$VerifyBoard = "tel"

# Cloned as siblings of solar_workspace. Only firmware_v4 gets further setup;
# the rest are just cloned (see each repo's README for its own setup).
$Repos = @($FwRepo, "sunlite", "solar_tools")

# Installed with winget when Test says it's missing
$WingetPackages = @(
    @{ Id = "Git.Git";                    Name = "Git";    Test = { Test-Command git } }
    @{ Id = "RubyInstallerTeam.Ruby.3.3"; Name = "Ruby";   Test = { Test-Command ruby } }  # runs the vendored Ceedling
    @{ Id = "ezwinports.make";            Name = "make";   Test = { Test-Command make } }  # firmware_v4's top-level Makefile
    @{ Id = "NordicSemiconductor.JLink";  Name = "J-Link"; Test = { Test-Path "$env:ProgramFiles\SEGGER\JLink*\JLink.exe" }; Detached = "JLink_Windows" }  # J-Link USB driver (SEGGER's installer, published by Nordic; x64 only)
)

$VSCodeExtensions = @(
    "stmicroelectronics.stm32-vscode-extension"  # STM32Cube for VS Code (pulls in the stm32cube-ide-* pack)
    "ms-vscode.cmake-tools"
    "marus25.cortex-debug"                       # SWO printing
)

$CubeMXSetting = "stm32cube-ide-core.configuration.productSTM32CubeMX.executablePath"
$CubeMXCandidates = @(
    "$env:ProgramFiles\STMicroelectronics\STM32Cube\STM32CubeMX\STM32CubeMX.exe"
    "$env:LOCALAPPDATA\Programs\STMicroelectronics\STM32Cube\STM32CubeMX\STM32CubeMX.exe"
    "$env:USERPROFILE\STM32CubeMX\STM32CubeMX.exe"
)

$VSCodeUserDir = Join-Path $env:APPDATA "Code\User"
$VSCodeExtDir = Join-Path $env:USERPROFILE ".vscode\extensions"
# Where cube installs bundles when CUBE_BUNDLE_PATH isn't set; asked from cube itself when possible
$DefaultBundleDir = Join-Path $env:LOCALAPPDATA "stm32cube\bundles"

# Backups get a timestamp so re-running never overwrites an earlier one
$BackupSuffix = ".bak-bootstrap-" + (Get-Date -Format "yyyyMMdd-HHmmss")

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------
$Notes = New-Object System.Collections.Generic.List[string]
$NeedsVSCodeRestart = $false

function Step([string]$Msg) { Write-Host ""; Write-Host "==> $Msg" -ForegroundColor White }
function Ok([string]$Msg)   { Write-Host "  + " -ForegroundColor Green -NoNewline; Write-Host $Msg }
function Skip([string]$Msg) { Write-Host "  - " -ForegroundColor Yellow -NoNewline; Write-Host $Msg }
function Warn([string]$Msg) { Write-Host "  ! " -ForegroundColor Yellow -NoNewline; Write-Host $Msg; $Notes.Add($Msg) }
function Die([string]$Msg)  { Write-Host "error: " -ForegroundColor Red -NoNewline; Write-Host $Msg; exit 1 }
function DryRunMsg([string]$Msg) { Write-Host "  [dry-run] " -ForegroundColor Yellow -NoNewline; Write-Host $Msg }

function Test-Command([string]$Name) {
    [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

# Run a native program. With -Stream its output is shown indented as it runs; otherwise it's
# captured. Native stderr must not go through PowerShell's error stream, or 'Stop' aborts the
# script on the first warning a tool prints.
function Invoke-Native {
    param([string]$Exe, [string[]]$Arguments, [switch]$Stream)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        if ($Stream) {
            & $Exe @Arguments 2>&1 | ForEach-Object { Write-Host "    $_" }
            $out = @()
        } else {
            $out = @(& $Exe @Arguments 2>&1 | ForEach-Object { "$_" })
        }
    } finally {
        $ErrorActionPreference = $prev
    }
    [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $out }
}

# winget installs don't update the PATH of an already running session
function Update-SessionPath {
    $paths = @([Environment]::GetEnvironmentVariable('Path', 'Machine'),
               [Environment]::GetEnvironmentVariable('Path', 'User')) | Where-Object { $_ }
    $env:Path = $paths -join ';'
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
if ([Environment]::OSVersion.Platform -ne 'Win32NT') {
    Die "this script is for Windows; on Ubuntu use bootstrap.sh"
}
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    # Elevated, the per-user parts (env var, VS Code settings, bundles) can end up in the admin's profile
    Die "run this from a normal PowerShell/cmd window, not 'Run as administrator' (installers ask for admin rights when needed)"
}

Write-Host "UBC Solar firmware bootstrap" -ForegroundColor White
Write-Host "  OS:        $((Get-CimInstance Win32_OperatingSystem).Caption)"
Write-Host "  Workspace: $ParentDir"
if ($DryRun) { Write-Host "  Dry run: nothing will be changed" -ForegroundColor Yellow }

# ---------------------------------------------------------------------------
# VS Code detection
# ---------------------------------------------------------------------------
# code.cmd for the user installer (default), the system installer, or whatever is on PATH
function Find-VSCode {
    $cmd = Get-Command code.cmd -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    foreach ($candidate in @("$env:LOCALAPPDATA\Programs\Microsoft VS Code\bin\code.cmd",
                             "$env:ProgramFiles\Microsoft VS Code\bin\code.cmd")) {
        if (Test-Path $candidate) { return $candidate }
    }
    return $null
}
$Code = Find-VSCode

# ---------------------------------------------------------------------------
# 1. Programs (winget) + VS Code
# ---------------------------------------------------------------------------
# SEGGER's installer relaunches itself elevated from %TEMP% and exits with 2 straight away, so
# winget reports a failure while the real install carries on in the background.
function Wait-DetachedInstaller([string]$Process, [int]$TimeoutSec = 300) {
    Start-Sleep -Seconds 2
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Process $Process -ErrorAction SilentlyContinue) -and (Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 2
    }
}

function Install-WingetPackage([string]$Id, [string]$Name, [scriptblock]$Test = $null, [string]$Detached = "") {
    if ($DryRun) { DryRunMsg "winget install --id $Id"; return }
    Write-Host "  installing $Name ($Id)..."
    $r = Invoke-Native winget @("install", "--id", $Id, "--exact", "--silent",
                                "--accept-package-agreements", "--accept-source-agreements")
    if ($r.ExitCode -ne 0 -and $Detached) {
        Write-Host "  waiting for the $Name installer to finish..."
        Wait-DetachedInstaller $Detached
    }
    if ($r.ExitCode -eq 0 -or ($Detached -and (& $Test))) {
        Ok "installed $Name"
    } else {
        $r.Output | Select-Object -Last 5 | ForEach-Object { Write-Host "    $_" }
        Warn "couldn't install $Name with winget (exit $($r.ExitCode)); install it manually: winget install --id $Id"
    }
}

Step "Programs (winget)"
if ($SkipInstall) {
    Skip "skipped (-SkipInstall)"
} elseif (-not (Test-Command winget)) {
    Warn "winget not found; install 'App Installer' from the Microsoft Store and re-run, or install Git, Ruby, make, J-Link and VS Code by hand"
} else {
    $missing = @($WingetPackages | Where-Object { -not (& $_.Test) })
    if ($missing.Count -eq 0) {
        Ok "all programs already installed"
    } else {
        foreach ($pkg in $missing) { Install-WingetPackage $pkg.Id $pkg.Name $pkg.Test $pkg.Detached }
    }

    if ($Code) {
        Ok "VS Code already installed ($Code)"
    } else {
        Install-WingetPackage "Microsoft.VisualStudioCode" "VS Code"
        if ($DryRun) {
            # Pretend it's there so the later steps show what they would do
            $Code = "code.cmd"
        }
    }
    if (-not $DryRun) {
        Update-SessionPath
        if (-not $Code) { $Code = Find-VSCode }
    }
}

if (-not $DryRun -and -not (Test-Command git)) {
    Die "git isn't available; install Git for Windows (winget install --id Git.Git) and re-run"
}

# ---------------------------------------------------------------------------
# 2. Debug probe drivers
# ---------------------------------------------------------------------------
# No dialout group on Windows: any user can open COM ports. J-Link's driver comes with the
# SEGGER package above; ST-LINK's needs an ST account, so only check for it.
Step "Debug probe drivers"
if (Test-Path "$env:ProgramFiles\SEGGER\JLink*\JLink.exe") {
    Ok "J-Link software + driver installed"
} elseif (-not $SkipInstall -and -not $DryRun) {
    Warn "J-Link software not found in $env:ProgramFiles\SEGGER; install it from segger.com (J-Link Software and Documentation Pack) for the J-Link USB driver"
}
$drivers = Invoke-Native pnputil @("/enum-drivers")
if ($drivers.ExitCode -ne 0) {
    Skip "couldn't list installed drivers; make sure the ST-LINK driver (STSW-LINK009) is installed"
} elseif ($drivers.Output -match 'stlink') {
    Ok "ST-LINK driver installed"
} else {
    Warn "ST-LINK USB driver not found; download STSW-LINK009 from st.com (needs an ST account) and run dpinst_amd64.exe"
}

# ---------------------------------------------------------------------------
# 3. Repos
# ---------------------------------------------------------------------------
Step "Repositories"
foreach ($repo in $Repos) {
    $dir = Join-Path $ParentDir $repo
    if ($Ssh) { $url = "git@github.com:$GithubOrg/$repo.git" } else { $url = "https://github.com/$GithubOrg/$repo.git" }

    if (Test-Path (Join-Path $dir ".git")) {
        Ok "$repo already cloned (left untouched)"
    } elseif (Test-Path $dir) {
        if ($repo -eq $FwRepo) { Die "$dir exists but is not a git repo; move it aside and re-run" }
        Warn "$dir exists but is not a git repo; skipped $repo"
    } elseif ($DryRun) {
        DryRunMsg "git clone --recurse-submodules $url $dir"
    } else {
        # CubeMX/HAL paths go past Windows' 260-character limit; longpaths is stored in this clone only
        $r = Invoke-Native git @("-c", "core.longpaths=true", "clone", "--quiet", "--recurse-submodules",
                                 "--config", "core.longpaths=true", $url, $dir)
        if ($r.ExitCode -ne 0) {
            $r.Output | ForEach-Object { Write-Host "    $_" }
            if ($repo -eq $FwRepo) { Die "couldn't clone $repo" }
            Warn "couldn't clone $repo"
        } else {
            Ok "cloned $repo"
        }
    }
}

if (Test-Path (Join-Path $FwDir ".git")) {
    $hooksPath = (Invoke-Native git @("-C", $FwDir, "config", "--get", "core.hooksPath")).Output -join ""
    if ($hooksPath -eq ".githooks") {
        Ok "$FwRepo git hooks already installed"
    } elseif ($DryRun) {
        DryRunMsg "git -C $FwDir config core.hooksPath .githooks"
    } else {
        # Same as 'make hooks', without needing make
        Invoke-Native git @("-C", $FwDir, "config", "core.hooksPath", ".githooks") | Out-Null
        Ok "$FwRepo git hooks installed (branch naming checks)"
    }

    # With core.autocrlf=true (Git for Windows' default) the hook scripts get CRLF line endings
    # and sh fails on them with "bad interpreter" unless .gitattributes pins them to LF
    $hook = Join-Path $FwDir ".githooks\pre-commit"
    if ((Test-Path $hook) -and ([IO.File]::ReadAllText($hook) -match "`r")) {
        Warn "$FwRepo's git hooks were checked out with CRLF line endings and will fail; in $FwRepo run: Remove-Item .githooks\*; git -c core.autocrlf=input checkout -- .githooks"
    }
}

# ---------------------------------------------------------------------------
# 4. VS Code extensions
# ---------------------------------------------------------------------------
Step "VS Code extensions"
if (-not $Code) {
    Warn "VS Code not found; install it (https://code.visualstudio.com) and re-run"
} else {
    # If listing fails, treat everything as missing; --install-extension is idempotent
    $installed = @()
    if (-not $DryRun -or (Test-Path $Code)) {
        $installed = (Invoke-Native $Code @("--list-extensions")).Output | ForEach-Object { $_.ToLower() }
    }
    foreach ($ext in $VSCodeExtensions) {
        if ($installed -contains $ext.ToLower()) {
            Ok "$ext already installed"
        } elseif ($DryRun) {
            DryRunMsg "code --install-extension $ext --force"
        } else {
            $r = Invoke-Native $Code @("--install-extension", $ext, "--force")
            if ($r.ExitCode -eq 0) {
                Ok "installed $ext"
                $NeedsVSCodeRestart = $true
            } else {
                $r.Output | Select-Object -Last 5 | ForEach-Object { Write-Host "    $_" }
                Warn "couldn't install $ext; install it from the Extensions view in VS Code"
            }
        }
    }
}

# ---------------------------------------------------------------------------
# 5. STM32Cube bundles
# ---------------------------------------------------------------------------
# Same as the wiki's Bundles Manager + "cube bundle show --project" steps, using the
# cube CLI that ships inside the STM32Cube core extension.
Step "STM32Cube bundles (versions pinned by $FwRepo)"

# Version of a bundle pinned in firmware_v4/.settings/bundles.store.json
$BundleStore = Join-Path $FwDir ".settings\bundles.store.json"
$BundleVersions = @{}
if (Test-Path $BundleStore) {
    foreach ($b in (Get-Content -Raw $BundleStore | ConvertFrom-Json).bundles) { $BundleVersions[$b.name] = $b.version }
}
$FwGccVersion = $BundleVersions["gnu-tools-for-stm32"]
$FwJLinkVersion = $BundleVersions["jlink-gdbserver"]
$FwCMakeVersion = $BundleVersions["cmake"]
$FwNinjaVersion = $BundleVersions["ninja"]

# Newest installed STM32Cube core extension's cube.exe
$Cube = Get-ChildItem -Path $VSCodeExtDir -Directory -Filter "stmicroelectronics.stm32cube-ide-core-*" -ErrorAction SilentlyContinue |
    Sort-Object { if ($_.Name -match '-(\d+(\.\d+)+)') { [version]$Matches[1] } else { [version]"0.0" } } |
    ForEach-Object { Get-ChildItem -Path (Join-Path $_.FullName "resources\binaries") -Recurse -Filter cube.exe -ErrorAction SilentlyContinue } |
    Where-Object { $env:PROCESSOR_ARCHITECTURE -eq "ARM64" -or $_.FullName -notmatch '\\(arm64|aarch64)\\' } |
    Select-Object -Last 1 -ExpandProperty FullName

# A CUBE_BUNDLE_PATH that's already set (by an earlier run, or by you) wins, like it does for cube.
# Otherwise ask cube for its default, so this doesn't depend on guessing ST's layout.
if ($env:CUBE_BUNDLE_PATH) {
    $BundleDir = $env:CUBE_BUNDLE_PATH
} else {
    $BundleDir = $DefaultBundleDir
    if ($Cube) {
        $line = (Invoke-Native $Cube @("--get-current-value", "cube_bundle_path")).Output |
            Where-Object { $_ -like "cube_bundle_path=*" } | Select-Object -First 1
        if ($line -and $line.Substring("cube_bundle_path=".Length)) { $BundleDir = $line.Substring("cube_bundle_path=".Length) }
    }
}
$GccBinDir = Join-Path $BundleDir "gnu-tools-for-stm32\$FwGccVersion\bin"

if ($SkipBundles) {
    Skip "skipped (-SkipBundles)"
} elseif (-not $Code) {
    Skip "skipped (no VS Code)"
} elseif (-not $Cube) {
    if ($DryRun) {
        Skip "cube CLI not available until the extensions are installed"
    } else {
        Warn "couldn't find the cube CLI in $VSCodeExtDir; open the Bundles Manager in VS Code and install the project bundles"
    }
} elseif (-not (Test-Path $BundleStore)) {
    Warn "$FwRepo\.settings\bundles.store.json not found; skipped bundle install"
} else {
    Write-Host "  bundles dir: $BundleDir"
    if ($DryRun) {
        # Not cube's own --dry-run: it still downloads and installs for "bundle install"
        DryRunMsg "CUBE_BUNDLE_PATH=$BundleDir $Cube --cwd $FwDir bundle install --project --yes"
    } else {
        Write-Host "  installing (the toolchain is a large download, this can take a while)..."
        $env:CUBE_BUNDLE_PATH = $BundleDir
        $r = Invoke-Native $Cube @("--cwd", $FwDir, "bundle", "install", "--project", "--yes") -Stream
        # A failed download shouldn't abort the rest
        if ($r.ExitCode -ne 0) {
            Warn "cube bundle install failed (output above); re-run this script, or install the bundles from the Bundles Manager in VS Code"
        } elseif (Test-Path (Join-Path $GccBinDir "arm-none-eabi-gcc.exe")) {
            Ok "project bundles installed (gnu-tools-for-stm32 $FwGccVersion)"
        } else {
            Warn "bundle install finished but $GccBinDir\arm-none-eabi-gcc.exe is missing; check the Bundles Manager in VS Code"
        }
    }
}

# ---------------------------------------------------------------------------
# 6. Environment (CUBE_BUNDLE_PATH, J-Link on PATH)
# ---------------------------------------------------------------------------
# Referenced as ${env:CUBE_BUNDLE_PATH} by the solar_workspace and firmware_v4 .vscode settings.
# User environment variables replace bootstrap.sh's ~/.bashrc block: VS Code and new
# terminals pick them up once restarted. Cortex-Debug gets the bundle's gdb through
# settings.json (step 7); Windows has no gdb-multiarch fallback.
Step "Environment (CUBE_BUNDLE_PATH, J-Link on PATH)"
$userValue = [Environment]::GetEnvironmentVariable('CUBE_BUNDLE_PATH', 'User')
$machineValue = [Environment]::GetEnvironmentVariable('CUBE_BUNDLE_PATH', 'Machine')
if ($userValue -eq $BundleDir) {
    Ok "CUBE_BUNDLE_PATH already set ($BundleDir)"
} elseif ($userValue -or $machineValue) {
    $own = if ($userValue) { $userValue } else { $machineValue }
    Ok "CUBE_BUNDLE_PATH comes from your own config ($own); left alone"
    if ($own -ne $BundleDir) { Warn "CUBE_BUNDLE_PATH is $own but the bundles were installed in $BundleDir" }
} elseif ($DryRun) {
    DryRunMsg "set user environment variable CUBE_BUNDLE_PATH=$BundleDir"
} else {
    [Environment]::SetEnvironmentVariable('CUBE_BUNDLE_PATH', $BundleDir, 'User')
    $env:CUBE_BUNDLE_PATH = $BundleDir
    Ok "set user environment variable CUBE_BUNDLE_PATH=$BundleDir"
    $NeedsVSCodeRestart = $true
}

# J-Link on PATH: JLink.exe for flashing from a terminal, and JLinkGDBServerCL.exe as
# Cortex-Debug's fallback when cortex-debug.JLinkGDBServerPath.windows isn't set.
# Prefer the newest SEGGER install (it has the USB driver and the newest device support);
# the jlink-gdbserver bundle is the fallback.
function Find-JLinkDir {
    $segger = @("$env:ProgramFiles\SEGGER", "${env:ProgramFiles(x86)}\SEGGER") |
        Where-Object { $_ -and (Test-Path $_) } |
        ForEach-Object { Get-ChildItem -Path $_ -Directory -Filter "JLink*" -ErrorAction SilentlyContinue } |
        Where-Object { Test-Path (Join-Path $_.FullName "JLink.exe") } |
        # JLink_V880 < JLink_V880a < JLink_V890; an unversioned "JLink" folder sorts first
        Sort-Object { if ($_.Name -match '_V(\d+)([a-z]?)$') { "{0:D6}{1}" -f [int]$Matches[1], $Matches[2] } else { "000000" } } |
        Select-Object -Last 1 -ExpandProperty FullName
    if ($segger) { return $segger }
    if ($FwJLinkVersion) {
        return Get-ChildItem -Path (Join-Path $BundleDir "jlink-gdbserver\$FwJLinkVersion") -Recurse -Filter JLink.exe `
            -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty DirectoryName
    }
    return $null
}

# Tell Explorer (and anything started from it later) that the environment changed
function Send-EnvironmentChange {
    if (-not ("Win32.NativeMethods" -as [type])) {
        Add-Type -Namespace Win32 -Name NativeMethods -MemberDefinition @'
[DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Auto)]
public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint Msg, UIntPtr wParam, string lParam,
    uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);
'@
    }
    $result = [UIntPtr]::Zero
    # HWND_BROADCAST, WM_SETTINGCHANGE, SMTO_ABORTIFHUNG
    [Win32.NativeMethods]::SendMessageTimeout([IntPtr]0xffff, 0x1A, [UIntPtr]::Zero, "Environment", 2, 5000, [ref]$result) | Out-Null
}

function Get-PathEntries([string]$Path) {
    @($Path -split ';' | Where-Object { $_.Trim() })
}
function Normalize-Dir([string]$Dir) {
    [Environment]::ExpandEnvironmentVariables($Dir).Trim().TrimEnd('\')
}

$JLinkDir = Find-JLinkDir
if (-not $JLinkDir) {
    if ($DryRun) {
        Skip "no J-Link install yet; would add it to PATH once installed"
    } else {
        Warn "no J-Link install found (SEGGER or jlink-gdbserver bundle), so JLink.exe isn't on PATH; install the J-Link Software pack and re-run"
    }
} else {
    # Read the user PATH unexpanded and write it back as REG_EXPAND_SZ, so entries like
    # %USERPROFILE%\... keep working ([Environment]::SetEnvironmentVariable would expand them)
    $envKey = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey("Environment", $true)
    try {
        $userPath = [string]$envKey.GetValue("Path", "", [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        $userEntries = Get-PathEntries $userPath
        $machineEntries = Get-PathEntries ([Environment]::GetEnvironmentVariable('Path', 'Machine'))

        # Entries this script manages: SEGGER installs and the bundle. Anything else with
        # JLink.exe in it is your own and is left alone.
        $isManaged = {
            param($d)
            $n = Normalize-Dir $d
            ($n -like "$env:ProgramFiles\SEGGER\JLink*") -or ($n -like "${env:ProgramFiles(x86)}\SEGGER\JLink*") -or
                ($n -like "$BundleDir\jlink-gdbserver\*")
        }
        $ownJLink = @($userEntries + $machineEntries) | Where-Object {
            -not (& $isManaged $_) -and (Test-Path (Join-Path (Normalize-Dir $_) "JLink.exe"))
        } | Select-Object -First 1
        $managed = @($userEntries | Where-Object { & $isManaged $_ })
        $machineManaged = @($machineEntries | Where-Object { (Normalize-Dir $_) -eq $JLinkDir })

        if ($ownJLink) {
            Ok "J-Link already on PATH from your own config ($ownJLink); left alone"
        } elseif ($machineManaged -or ($managed.Count -eq 1 -and (Normalize-Dir $managed[0]) -eq $JLinkDir)) {
            Ok "J-Link already on PATH ($JLinkDir)"
        } elseif ($DryRun) {
            DryRunMsg "put $JLinkDir on the user PATH"
            foreach ($old in $managed) { DryRunMsg "remove old J-Link entry $old from the user PATH" }
        } else {
            # Replaces an older J-Link entry (e.g. after upgrading JLink_V880 -> JLink_V890)
            $newEntries = @($userEntries | Where-Object { -not (& $isManaged $_) }) + $JLinkDir
            $envKey.SetValue("Path", ($newEntries -join ';'), [Microsoft.Win32.RegistryValueKind]::ExpandString)
            Send-EnvironmentChange
            $env:Path = "$env:Path;$JLinkDir"
            foreach ($old in $managed) { Ok "removed old J-Link entry $old from the user PATH" }
            Ok "put $JLinkDir on the user PATH (JLink.exe, JLinkGDBServerCL.exe)"
            $NeedsVSCodeRestart = $true
        }
    } finally {
        $envKey.Close()
    }
}

# ---------------------------------------------------------------------------
# 7. VS Code user settings (CubeMX + Cortex-Debug)
# ---------------------------------------------------------------------------
# - CubeMX needs an st.com login to download, so it can't be installed here. If it's
#   already installed, point the STM32 extension at it (wiki: "Absolute path to CubeMx").
# - The "J-Link + SWO" launch config in firmware_v4 uses Cortex-Debug, which looks for
#   arm-none-eabi-gdb on PATH. Point it at the gdb and J-Link GDB server from the bundles.
Step "VS Code settings (STM32CubeMX, Cortex-Debug)"
$SettingsFile = Join-Path $VSCodeUserDir "settings.json"
$Wanted = [ordered]@{}

if (-not $CubeMX) {
    $CubeMX = $CubeMXCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
}
if (-not $CubeMX) {
    Warn "STM32CubeMX not found. Install it manually (needs an ST account, see the README), then re-run this script"
} elseif (-not (Test-Path $CubeMX -PathType Leaf)) {
    Warn "$CubeMX is not a file; pass the STM32CubeMX.exe path with -CubeMX"
} else {
    $Wanted[$CubeMXSetting] = (Resolve-Path $CubeMX).Path
}

$Gdb = Join-Path $GccBinDir "arm-none-eabi-gdb.exe"
if ($FwGccVersion -and (Test-Path $Gdb)) {
    $Wanted["cortex-debug.gdbPath.windows"] = $Gdb
    $Wanted["cortex-debug.armToolchainPath.windows"] = $GccBinDir
} elseif (-not $DryRun) {
    Warn "arm-none-eabi-gdb.exe not found in $GccBinDir (bundles not installed?); Cortex-Debug launch configs won't work until cortex-debug.gdbPath is set"
}

# Searched for rather than hard-coded: the bundle's layout on Windows isn't documented
if ($FwJLinkVersion) {
    $JLinkServer = Get-ChildItem -Path (Join-Path $BundleDir "jlink-gdbserver\$FwJLinkVersion") -Recurse `
        -Filter JLinkGDBServerCL.exe -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName
    if ($JLinkServer) { $Wanted["cortex-debug.JLinkGDBServerPath.windows"] = $JLinkServer }
}

# Each key is only set if it's missing or points at a path that doesn't exist, so paths you've
# set yourself (e.g. a SEGGER J-Link install) are kept. settings.json may contain comments
# (JSONC); it's only edited if it's plain JSON, since rewriting it would drop them.
function Update-VSCodeSettings([string]$Path, $Pairs) {
    $settings = New-Object psobject
    if (Test-Path $Path) {
        $text = [IO.File]::ReadAllText($Path)
        if ($text.Trim()) {
            $noStrings = [regex]::Replace($text, '"(?:[^"\\]|\\.)*"', '""')
            if ($noStrings -match '//|/\*|,\s*[}\]]') { return $false }
            try { $settings = $text | ConvertFrom-Json } catch { return $false }
        }
    }
    $changed = $false
    foreach ($key in $Pairs.Keys) {
        $value = $Pairs[$key]
        $prop = $settings.PSObject.Properties[$key]
        $current = if ($prop) { $prop.Value } else { $null }
        if ($current -eq $value -or ($current -is [string] -and $current -and (Test-Path $current))) {
            Ok "already set: $key = $current"
        } else {
            $settings | Add-Member -NotePropertyName $key -NotePropertyValue $value -Force
            $changed = $true
            if ($DryRun) { DryRunMsg "set $key = $value" } else { Ok "set $key = $value" }
        }
    }
    if ($changed -and -not $DryRun) {
        if (Test-Path $Path) {
            Copy-Item $Path "$Path$BackupSuffix"
            Write-Host "  (previous settings backed up to $Path$BackupSuffix)"
        }
        New-Item -ItemType Directory -Force -Path (Split-Path $Path) | Out-Null
        # UTF-8 without a BOM, like VS Code writes it
        [IO.File]::WriteAllText($Path, ($settings | ConvertTo-Json -Depth 100) + "`n", (New-Object Text.UTF8Encoding $false))
    }
    return $true
}

if (-not $Code) {
    Skip "skipped (no VS Code)"
} elseif ($Wanted.Count -eq 0) {
    Skip "nothing to set"
} elseif (-not (Update-VSCodeSettings $SettingsFile $Wanted)) {
    $list = ($Wanted.Keys | ForEach-Object { "$_ = $($Wanted[$_])" }) -join "; "
    Warn "couldn't edit $SettingsFile automatically (not plain JSON); set these in VS Code settings: $list"
}

# ---------------------------------------------------------------------------
# 8. Verify build
# ---------------------------------------------------------------------------
Step "Verify toolchain (build $VerifyBoard into a temp dir)"
if ($SkipVerify) {
    Skip "skipped (-SkipVerify)"
} elseif ($DryRun) {
    Skip "skipped (dry run)"
} else {
    # The bundled toolchain is what VS Code builds with; anything on PATH is the fallback
    foreach ($bundleBin in @($GccBinDir,
                             (Join-Path $BundleDir "cmake\$FwCMakeVersion\bin"),
                             (Join-Path $BundleDir "ninja\$FwNinjaVersion\bin"))) {
        if (Test-Path $bundleBin) { $env:Path = "$bundleBin;$env:Path" }
    }

    $missingTools = @("cmake", "ninja", "arm-none-eabi-gcc") | Where-Object { -not (Test-Command $_) }
    # firmware_v4's CMakePresets.json is schema version 3
    $CMakeMin = [version]"3.21"
    $cmakeVersion = $null
    if (Test-Command cmake) {
        $first = (Invoke-Native cmake @("--version")).Output | Select-Object -First 1
        if ($first -match '(\d+\.\d+(\.\d+)?)') { $cmakeVersion = [version]$Matches[1] }
    }

    if ($missingTools) {
        Warn "can't verify: missing $($missingTools -join ', ') (re-run without -SkipBundles?)"
    } elseif (-not $cmakeVersion -or $cmakeVersion -lt $CMakeMin) {
        Warn "can't verify: cmake $cmakeVersion is older than $CMakeMin (needed for CMake presets); install the STM32Cube bundles, which include a newer CMake"
    } else {
        # Build outside the repo so an existing VS Code build\ dir is never touched
        $buildTmp = Join-Path $env:TEMP ("ubcsolar-bootstrap-" + [guid]::NewGuid().ToString("N").Substring(0, 8))
        $src = Join-Path $FwDir "firmware\components\$VerifyBoard"
        $log = New-Object System.Collections.Generic.List[string]
        try {
            $configure = Invoke-Native cmake @("--preset", "Debug", "-S", $src, "-B", "$buildTmp\build")
            $log.AddRange([string[]]$configure.Output)
            $built = $false
            if ($configure.ExitCode -eq 0) {
                $build = Invoke-Native cmake @("--build", "$buildTmp\build")
                $log.AddRange([string[]]$build.Output)
                $built = ($build.ExitCode -eq 0) -and (Get-ChildItem -Path "$buildTmp\build" -Recurse -Filter *.elf -ErrorAction SilentlyContinue)
            }
            if ($built) {
                $gccVersion = ((Invoke-Native arm-none-eabi-gcc @("-dumpversion")).Output -join "").Trim()
                $gccDir = Split-Path (Get-Command arm-none-eabi-gcc).Source
                Ok "$VerifyBoard built successfully (arm-none-eabi-gcc $gccVersion from $gccDir)"
            } else {
                $log | Select-Object -Last 20 | ForEach-Object { Write-Host "    $_" }
                $logFile = Join-Path $ParentDir "bootstrap-build.log"
                $log | Set-Content -Path $logFile
                Warn "test build of $VerifyBoard failed; full log: $logFile"
            }
        } finally {
            Remove-Item -Recurse -Force $buildTmp -ErrorAction SilentlyContinue
        }
    }
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
Step "Done"
if ($Notes.Count -gt 0) {
    Write-Host "  Needs attention:" -ForegroundColor Yellow
    foreach ($note in $Notes) { Write-Host "    - $note" }
}

Write-Host "  Next steps:" -ForegroundColor White
# VS Code reads the environment once, when its first window starts
if ($NeedsVSCodeRestart) {
    Write-Host "    - Open a new terminal to pick up CUBE_BUNDLE_PATH and the new programs on PATH (JLink.exe, git, make)"
}
Write-Host "    - If VS Code is open, quit it completely (every window), then open the workspace:"
Write-Host "        code `"$ScriptDir\solar-workspace.code-workspace`""
Write-Host "    - In VS Code, pick a project + configuration in the CMake panel and build"
Write-Host "    - Build from the terminal: make -C `"$FwDir`" all debug"
Write-Host "    - Telemetry (sunlink) is set up separately: see the solar_workspace README"
