# UBC Solar Workspace

This workspace is meant to group the UBC Solar repositories into one VS Code workspace so they can be edited together.

## Folder structure

Place the repositories as sibling folders inside the same parent directory:

```text
~/Desktop/UBC_Solar/
├── solar_workspace/    # this workspace folder
├── firmware_v4/
├── sunlink/
├── sunlite/
└── solar_tools/
```

The workspace file [solar-workspace.code-workspace](solar-workspace.code-workspace) already points to these folders relative to the parent directory.

## Quick setup (firmware, Ubuntu)

> [!IMPORTANT]
> **Install STM32CubeMX manually first.** The download needs an ST account, so the bootstrap script can't install it for you.
>
> 1. Go to [st.com/stm32cubemx](https://www.st.com/en/development-tools/stm32cubemx) → **Get Software** → **Get latest**, then sign in or create an account. After signing in, click **Get latest** again to download the ZIP.
> 2. Extract the ZIP and run the `SetupSTM32CubeMX-*` installer inside it. Keep the default install location, `~/STM32CubeMX`.
>
> The bootstrap script finds CubeMX in `~/STM32CubeMX` and points the STM32 VS Code extension at it. If you installed it somewhere else, pass `--cubemx /path/to/STM32CubeMX`. If you install CubeMX after running the bootstrap, run the script again.

Then clone this repo into your parent folder and run the bootstrap script:

```bash
mkdir -p ~/Desktop/UBC_Solar && cd ~/Desktop/UBC_Solar
git clone https://github.com/UBC-Solar/solar_workspace.git
./solar_workspace/bootstrap.sh
```

This automates the Ubuntu steps of the wiki's *How to Install STM32 VS Code for Firmware_v4 Development*:

- Installs the ARM toolchain, CMake and Ninja (the same packages as firmware_v4 CI), plus Ruby for Ceedling, `gdb-multiarch` and ST-LINK udev rules. It also installs VS Code if it's missing.
- Adds you to the `dialout` group.
- Clones `firmware_v4`, `sunlite` and `solar_tools` next to this folder and installs the `firmware_v4` git hooks. Only `firmware_v4` is set up beyond cloning.
- Installs the STM32Cube, CMake Tools and Cortex-Debug VS Code extensions.
- Installs the STM32Cube bundles that `firmware_v4/.settings/bundles.store.json` pins, so you don't need the Bundles Manager.
- Adds a marked block to `~/.bashrc` (and `~/.zshrc` if zsh is your login shell) that sets `CUBE_BUNDLE_PATH` and puts `~/.local/bin` on `PATH`. It works with .deb, Snap and Flatpak VS Code.
- Points the STM32 extension at your STM32CubeMX install. It doesn't install CubeMX itself; see the note above.
- Points Cortex-Debug at the bundle's `arm-none-eabi-gdb` and J-Link GDB server, and installs the J-Link udev rules. The "J-Link + SWO" debug config needs these, because apt's `gcc-arm-none-eabi` doesn't include gdb. Paths you've already set yourself are kept. As a fallback, it also links `~/.local/bin/arm-none-eabi-gdb` to `gdb-multiarch` (the wiki's *JLINK SWO* steps); this fallback doesn't work with Flatpak VS Code, which needs the bundles.

After it finishes, quit VS Code completely (every window) and reopen it, so it picks up the new environment.
- Test-builds one board.

It's safe to re-run, and existing clones are left untouched. Run `./bootstrap.sh --help` for options (`--ssh`, `--cubemx`, `--skip-apt`, `--skip-bundles`, `--skip-verify`, `--dry-run`).

## Quick setup (firmware, Windows)

Install STM32CubeMX manually first, as in the Ubuntu note above (keep the default install location). The ST-LINK USB driver ([STSW-LINK009](https://www.st.com/en/development-tools/stsw-link009.html)) also needs an ST account, so install it the same way.

Then, from a normal PowerShell or cmd window (not "Run as administrator"):

```powershell
mkdir $HOME\Desktop\UBC_Solar; cd $HOME\Desktop\UBC_Solar
git clone https://github.com/UBC-Solar/solar_workspace.git
.\solar_workspace\bootstrap.cmd
```

No git yet? Run `winget install --id Git.Git -e` first, then open a new window.

`bootstrap.cmd` runs `bootstrap.ps1` without changing PowerShell's execution policy. It does the same steps as `bootstrap.sh`, with these differences:

- Uses winget to install Git, Ruby, make, the SEGGER J-Link software (for its USB driver) and VS Code, each only if it's missing. The installers ask for admin rights themselves.
- Takes the ARM toolchain, CMake and Ninja from the STM32Cube bundles only, with no system packages.
- Sets `CUBE_BUNDLE_PATH` as a user environment variable instead of in `~/.bashrc`, and puts the newest SEGGER J-Link folder (or the `jlink-gdbserver` bundle) on your user PATH so `JLink.exe` works from a terminal.
- Sets the `cortex-debug.*.windows` settings to the bundle's `arm-none-eabi-gdb.exe` and `JLinkGDBServerCL.exe`.
- Skips the `dialout` group and udev rules, which Windows doesn't need. It does check that the ST-LINK driver is installed.

Options: `-Ssh`, `-CubeMX <path to STM32CubeMX.exe>`, `-SkipInstall`, `-SkipBundles`, `-SkipVerify`, `-DryRun`. Afterwards, quit VS Code completely and reopen it.

## Telemetry (sunlink)

sunlink has its own installer, which also sets up Docker, InfluxDB and Grafana. Run it from the parent folder so `sunlink/` ends up next to the other repos:

```bash
cd ~/Desktop/UBC_Solar
curl -O https://raw.githubusercontent.com/UBC-Solar/sunlink/main/setup.sh
chmod +x setup.sh
./setup.sh
```

See the [sunlink README](https://github.com/UBC-Solar/sunlink#how-to-install-sunlink) for details.

## Manual setup

1. Create or open the parent folder:
   ```bash
   mkdir -p ~/Desktop/UBC_Solar
   cd ~/Desktop/UBC_Solar
   ```

2. Make sure the repositories exist in the expected locations:
   - `solar_workspace/`
   - `firmware_v4/`
   - `sunlink/`
   - `sunlite/`
   - `solar_tools/`

3. Open the workspace in VS Code:
   ```bash
   code ~/Desktop/UBC_Solar/solar_workspace/solar-workspace.code-workspace
   ```

   You can also open the folder directly:
   ```bash
   code ~/Desktop/UBC_Solar/solar_workspace
   ```

## Useful terminal commands

From your home directory:

```bash
cd ~/Desktop/UBC_Solar
code solar_workspace/solar-workspace.code-workspace
```

If you want to open the workspace from anywhere:

```bash
code ~/Desktop/UBC_Solar/solar_workspace/solar-workspace.code-workspace
```

## Notes

- Keep each repository in its own folder.
- Do not rename the folders unless you also update [solar-workspace.code-workspace](solar-workspace.code-workspace).
- If you add a new repository, add it to the `folders` section of [solar-workspace.code-workspace](solar-workspace.code-workspace).
