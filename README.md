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

Clone this repo into your parent folder, then run the bootstrap script:

```bash
mkdir -p ~/Desktop/UBC_Solar && cd ~/Desktop/UBC_Solar
git clone https://github.com/UBC-Solar/solar_workspace.git
./solar_workspace/bootstrap.sh
```

It installs the ARM toolchain (the same packages as firmware_v4 CI), Ruby for Ceedling, and ST-LINK udev rules. It also adds you to the `dialout` group, clones `firmware_v4`, `sunlink`, `sunlite` and `solar_tools` next to this folder, and installs the `firmware_v4` git hooks. Only `firmware_v4` is set up beyond cloning; see the other repos' READMEs for their own setup. The script also sets `CUBE_BUNDLE_PATH` and installs the STM32Cube VS Code extensions. To finish, it test-builds one board. It's safe to re-run, and existing clones are left untouched. Run `./bootstrap.sh --help` for options (`--ssh`, `--skip-apt`, `--skip-verify`, `--dry-run`).

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
