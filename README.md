# UBC Solar Workspace

This workspace is meant to group the UBC Solar repositories into one VS Code workspace so they can be edited together.

## Folder structure

Place the repositories as sibling folders inside the same parent directory:

```text
~/Desktop/UBC_Solar/
├── solar_workspace/    # this workspace folder
├── firmware_v4/
├── sunlink/
├── solar_tools/
└── firmware_v3/
```

The workspace file [solar-workspace.code-workspace](solar-workspace.code-workspace) already points to these folders relative to the parent directory.

## Setup

1. Create or open the parent folder:
   ```bash
   mkdir -p ~/Desktop/UBC_Solar
   cd ~/Desktop/UBC_Solar
   ```

2. Make sure the repositories exist in the expected locations:
   - `solar_workspace/`
   - `firmware_v4/`
   - `sunlink/`
   - `solar_tools/`
   - `firmware_v3/`

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
