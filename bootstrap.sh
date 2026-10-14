#!/usr/bin/env bash
# Bootstrap a UBC Solar firmware development environment (Ubuntu only).
#
# Automates the wiki's "How to Install STM32 VS Code for Firmware_v4 Development" for Ubuntu:
#   1. Installs the build toolchain (same packages as firmware_v4 CI), Ruby for Ceedling,
#      ST-LINK udev rules, and VS Code (if it isn't installed already)
#   2. Adds you to the dialout group
#   3. Clones firmware_v4, sunlite and solar_tools next to this folder (each skipped if
#      already present) and installs firmware_v4's git hooks
#   4. Installs the STM32Cube, CMake Tools and Cortex-Debug VS Code extensions
#   5. Installs the STM32Cube bundles pinned by firmware_v4 (.settings/bundles.store.json)
#   6. Sets CUBE_BUNDLE_PATH for the workspace's clangd settings
#   7. Points the STM32Cube extension at your STM32CubeMX install (if found)
#   8. Verifies the toolchain by building one board into a temporary directory
#
# sunlink is not handled here; it has its own setup.sh (see the README).
#
# Safe to re-run: every step checks whether it's already done, and nothing is deleted
# or overwritten.

set -euo pipefail

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARENT_DIR="$(dirname "$SCRIPT_DIR")"
GITHUB_ORG="UBC-Solar"
FW_REPO="firmware_v4"
FW_DIR="$PARENT_DIR/$FW_REPO"
VERIFY_BOARD="tel"

# Cloned as siblings of solar_workspace. Only firmware_v4 gets further setup;
# the rest are just cloned (see each repo's README for its own setup).
REPOS=("$FW_REPO" sunlite solar_tools)

APT_PACKAGES=(
    git make cmake ninja-build                 # build system
    gcc-arm-none-eabi libnewlib-arm-none-eabi  # ARM toolchain (matches firmware_v4 CI)
    ruby                                       # runs the vendored Ceedling in firmware_v4/tools/ceedling
    stlink-tools                               # st-flash/st-info + ST-LINK udev rules
    python3                                    # used below to read/edit JSON
)

VSCODE_EXTENSIONS=(
    stmicroelectronics.stm32-vscode-extension  # STM32Cube for VS Code (pulls in the stm32cube-ide-* pack)
    ms-vscode.cmake-tools
    marus25.cortex-debug                       # SWO printing
)

CUBEMX_SETTING="stm32cube-ide-core.configuration.productSTM32CubeMX.executablePath"
CUBEMX_CANDIDATES=(
    "$HOME/STM32CubeMX/STM32CubeMX"
    "/usr/local/STMicroelectronics/STM32Cube/STM32CubeMX/STM32CubeMX"
)

RC_FILE="$HOME/.bashrc"
RC_MARKER="# >>> UBC Solar firmware >>>"

USE_SSH=false
SKIP_APT=false
SKIP_BUNDLES=false
SKIP_VERIFY=false
DRY_RUN=false
CUBEMX_PATH=""

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------
RED="\033[0;31m"; GREEN="\033[0;32m"; YELLOW="\033[1;33m"; BOLD="\033[1m"; RESET="\033[0m"

step() { echo -e "\n${BOLD}==> $*${RESET}"; }
ok()   { echo -e "  ${GREEN}✓${RESET} $*"; }
skip() { echo -e "  ${YELLOW}-${RESET} $*"; }
warn() { echo -e "  ${YELLOW}!${RESET} $*"; NOTES+=("$*"); }
die()  { echo -e "${RED}error:${RESET} $*" >&2; exit 1; }

# Run a command, or just print it under --dry-run.
run() {
    if $DRY_RUN; then
        echo -e "  ${YELLOW}[dry-run]${RESET} $*"
    else
        "$@"
    fi
}

NOTES=()
NEEDS_RELOGIN=false
NEEDS_NEW_SHELL=false

usage() {
    cat <<EOF
Usage: ./bootstrap.sh [options]

Sets up the UBC Solar firmware_v4 development environment on Ubuntu.
Repos are placed next to this folder, in: $PARENT_DIR

Options:
  --ssh             Clone over SSH (git@github.com:...) instead of HTTPS
  --cubemx PATH     Path to your STM32CubeMX executable (default: auto-detect)
  --skip-apt        Don't install system packages or VS Code (no sudo needed for the rest)
  --skip-bundles    Don't download the STM32Cube bundles (large download)
  --skip-verify     Don't test-build firmware at the end
  --dry-run         Print what would be done without changing anything
  -h, --help        Show this help
EOF
}

# ---------------------------------------------------------------------------
# Args + preflight
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --ssh)          USE_SSH=true ;;
        --cubemx)       [[ $# -ge 2 ]] || die "--cubemx needs a path"; CUBEMX_PATH="$2"; shift ;;
        --skip-apt)     SKIP_APT=true ;;
        --skip-bundles) SKIP_BUNDLES=true ;;
        --skip-verify)  SKIP_VERIFY=true ;;
        --dry-run)      DRY_RUN=true ;;
        -h|--help)      usage; exit 0 ;;
        *)              usage; die "unknown option: $1" ;;
    esac
    shift
done

[[ $EUID -ne 0 ]] || die "run this as your normal user, not root (it uses sudo where needed)"

# shellcheck disable=SC1091
. /etc/os-release
[[ "${ID:-}" == "ubuntu" || " ${ID_LIKE:-} " == *" ubuntu "* ]] \
    || die "this script supports Ubuntu only (detected: ${PRETTY_NAME:-unknown})"

echo -e "${BOLD}UBC Solar firmware bootstrap${RESET}"
echo "  OS:        $PRETTY_NAME"
echo "  Workspace: $PARENT_DIR"
$DRY_RUN && echo -e "  ${YELLOW}Dry run: nothing will be changed${RESET}"

# ---------------------------------------------------------------------------
# VS Code detection
# ---------------------------------------------------------------------------
# The STM32 extension stores bundles under VS Code's data dir, which differs for
# .deb, Snap and Flatpak installs. Sets CODE (command array), VSCODE_KIND, and the
# data/config/extension dirs for that install.
detect_vscode() {
    local bin real
    CODE=(); VSCODE_KIND=none
    bin="$(command -v code 2>/dev/null || true)"
    if [[ -n "$bin" ]]; then
        real="$(readlink -f "$bin")"
        CODE=("$bin")
        if [[ "$bin" == /snap/* ]]; then
            VSCODE_KIND=snap
        elif [[ "$real" == */flatpak/* || "$bin" == */flatpak/* ]]; then
            VSCODE_KIND=flatpak
        else
            VSCODE_KIND=deb
        fi
    elif command -v flatpak >/dev/null 2>&1 && flatpak info com.visualstudio.code >/dev/null 2>&1; then
        CODE=(flatpak run com.visualstudio.code)
        VSCODE_KIND=flatpak
    fi

    case "$VSCODE_KIND" in
        flatpak)
            VSCODE_DATA="$HOME/.var/app/com.visualstudio.code/data"
            VSCODE_USER_DIR="$HOME/.var/app/com.visualstudio.code/config/Code/User"
            VSCODE_EXT_DIR="$VSCODE_DATA/vscode/extensions"
            BUNDLE_PATH_RC='$HOME/.var/app/com.visualstudio.code/data/stm32cube/bundles'
            ;;
        snap)
            VSCODE_DATA="$HOME/snap/code/current/.local/share"
            VSCODE_USER_DIR="$HOME/.config/Code/User"
            VSCODE_EXT_DIR="$HOME/.vscode/extensions"
            BUNDLE_PATH_RC='$HOME/snap/code/current/.local/share/stm32cube/bundles'
            ;;
        *)
            VSCODE_DATA="$HOME/.local/share"
            VSCODE_USER_DIR="$HOME/.config/Code/User"
            VSCODE_EXT_DIR="$HOME/.vscode/extensions"
            BUNDLE_PATH_RC='$HOME/.local/share/stm32cube/bundles'
            ;;
    esac
    BUNDLE_DIR="$VSCODE_DATA/stm32cube/bundles"
}

# Microsoft's apt repo, per https://code.visualstudio.com/docs/setup/linux
install_vscode() {
    run sudo apt-get install -y wget gpg
    if $DRY_RUN; then
        echo -e "  ${YELLOW}[dry-run]${RESET} add Microsoft apt repo + key, apt-get install code"
        return
    fi
    local key; key="$(mktemp)"
    wget -qO- https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor >"$key"
    sudo install -D -o root -g root -m 644 "$key" /usr/share/keyrings/microsoft.gpg
    rm -f "$key"
    sudo tee /etc/apt/sources.list.d/vscode.sources >/dev/null <<EOF
Types: deb
URIs: https://packages.microsoft.com/repos/code
Suites: stable
Components: main
Architectures: amd64,arm64,armhf
Signed-By: /usr/share/keyrings/microsoft.gpg
EOF
    sudo apt-get update
    sudo apt-get install -y code
}

detect_vscode

# ---------------------------------------------------------------------------
# 1. System packages + VS Code
# ---------------------------------------------------------------------------
step "System packages"
if $SKIP_APT; then
    skip "skipped (--skip-apt)"
else
    missing=()
    for pkg in "${APT_PACKAGES[@]}"; do
        dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "install ok installed" \
            || missing+=("$pkg")
    done

    if [[ ${#missing[@]} -eq 0 ]]; then
        ok "all packages already installed"
    else
        echo "  installing: ${missing[*]}"
        run sudo apt-get update
        run sudo apt-get install -y "${missing[@]}"
        # Pick up the ST-LINK udev rules shipped by stlink-tools
        run sudo udevadm control --reload-rules
        run sudo udevadm trigger
        ok "installed ${#missing[@]} package(s)"
    fi

    if [[ "$VSCODE_KIND" == none ]]; then
        echo "  VS Code not found; installing from Microsoft's apt repo"
        install_vscode
        detect_vscode
        ok "installed VS Code"
    else
        ok "VS Code already installed ($VSCODE_KIND)"
    fi
fi

if [[ "$VSCODE_KIND" == flatpak || "$VSCODE_KIND" == snap ]]; then
    warn "VS Code is a $VSCODE_KIND install; the integrated terminal is sandboxed, so apt tools (make, cmake, arm-none-eabi-gcc) may not be visible there. Building with the STM32 extension still works. The .deb from code.visualstudio.com avoids this."
fi

# ---------------------------------------------------------------------------
# 2. Serial port access
# ---------------------------------------------------------------------------
step "Serial port access (dialout group)"
if id -nG "$USER" | tr ' ' '\n' | grep -qx dialout; then
    ok "$USER is already in dialout"
elif $SKIP_APT; then
    warn "$USER is not in dialout; run: sudo usermod -aG dialout $USER"
else
    run sudo usermod -aG dialout "$USER"
    ok "added $USER to dialout"
    NEEDS_RELOGIN=true
fi

# ---------------------------------------------------------------------------
# 3. Repos
# ---------------------------------------------------------------------------
step "Repositories"
for repo in "${REPOS[@]}"; do
    dir="$PARENT_DIR/$repo"
    if $USE_SSH; then
        url="git@github.com:$GITHUB_ORG/$repo.git"
    else
        url="https://github.com/$GITHUB_ORG/$repo.git"
    fi

    if [[ -d "$dir/.git" ]]; then
        ok "$repo already cloned (left untouched)"
    elif [[ -e "$dir" ]]; then
        [[ "$repo" == "$FW_REPO" ]] && die "$dir exists but is not a git repo; move it aside and re-run"
        warn "$dir exists but is not a git repo; skipped $repo"
    else
        run git clone --quiet --recurse-submodules "$url" "$dir"
        ok "cloned $repo"
    fi
done

if [[ -d "$FW_DIR/.git" ]]; then
    if [[ "$(git -C "$FW_DIR" config --get core.hooksPath 2>/dev/null || true)" == ".githooks" ]]; then
        ok "$FW_REPO git hooks already installed"
    else
        run make -C "$FW_DIR" --no-print-directory hooks
        ok "$FW_REPO git hooks installed (branch naming checks)"
    fi
fi

# ---------------------------------------------------------------------------
# 4. VS Code extensions
# ---------------------------------------------------------------------------
step "VS Code extensions"
if [[ "$VSCODE_KIND" == none ]]; then
    warn "VS Code not found; install it (https://code.visualstudio.com/docs/setup/linux) and re-run"
else
    installed="$("${CODE[@]}" --list-extensions 2>/dev/null | tr '[:upper:]' '[:lower:]')"
    for ext in "${VSCODE_EXTENSIONS[@]}"; do
        if grep -qx "${ext,,}" <<<"$installed"; then
            ok "$ext already installed"
        else
            run "${CODE[@]}" --install-extension "$ext" --force >/dev/null 2>&1
            ok "installed $ext"
        fi
    done
fi

# ---------------------------------------------------------------------------
# 5. STM32Cube bundles
# ---------------------------------------------------------------------------
# Same as the wiki's Bundles Manager + "cube bundle show --project" steps, using the
# cube CLI that ships inside the STM32Cube core extension.
step "STM32Cube bundles (versions pinned by $FW_REPO)"
FW_GCC_VERSION="$(python3 -I -c '
import json, sys
for b in json.load(open(sys.argv[1]))["bundles"]:
    if b["name"] == "gnu-tools-for-stm32":
        print(b["version"])
' "$FW_DIR/.settings/bundles.store.json" 2>/dev/null || true)"

if $SKIP_BUNDLES; then
    skip "skipped (--skip-bundles)"
elif [[ "$VSCODE_KIND" == none ]]; then
    skip "skipped (no VS Code)"
else
    CUBE="$(compgen -G "$VSCODE_EXT_DIR/stmicroelectronics.stm32cube-ide-core-*/resources/binaries/linux/x86_64/cube" \
        | sort -V | tail -n 1 || true)"
    if [[ -z "$CUBE" ]]; then
        if $DRY_RUN; then
            skip "cube CLI not available until the extensions are installed"
        else
            warn "couldn't find the cube CLI in $VSCODE_EXT_DIR; open the Bundles Manager in VS Code and install the project bundles"
        fi
    elif [[ ! -f "$FW_DIR/.settings/bundles.store.json" ]]; then
        warn "$FW_REPO/.settings/bundles.store.json not found; skipped bundle install"
    else
        echo "  bundles dir: $BUNDLE_DIR"
        if $DRY_RUN; then
            # Not cube's own --dry-run: it still downloads and installs for "bundle install"
            echo -e "  ${YELLOW}[dry-run]${RESET} CUBE_BUNDLE_PATH=$BUNDLE_DIR $CUBE --cwd $FW_DIR bundle install --project --yes"
        else
            echo "  installing (the toolchain is a large download, this can take a while)..."
            CUBE_BUNDLE_PATH="$BUNDLE_DIR" "$CUBE" --cwd "$FW_DIR" bundle install --project --yes 2>&1 \
                | sed 's/^/    /'
            gcc_bin="$BUNDLE_DIR/gnu-tools-for-stm32/$FW_GCC_VERSION/bin/arm-none-eabi-gcc"
            if [[ -x "$gcc_bin" ]]; then
                ok "project bundles installed (gnu-tools-for-stm32 $FW_GCC_VERSION)"
            else
                warn "bundle install finished but $gcc_bin is missing; check the Bundles Manager in VS Code"
            fi
        fi
    fi
fi

# ---------------------------------------------------------------------------
# 6. CUBE_BUNDLE_PATH
# ---------------------------------------------------------------------------
step "CUBE_BUNDLE_PATH"
RC_EXPORT="export CUBE_BUNDLE_PATH=\"$BUNDLE_PATH_RC\""
if grep -qF "$RC_MARKER" "$RC_FILE" 2>/dev/null; then
    if sed -n "/^$RC_MARKER\$/,/^# <<< UBC Solar firmware <<<\$/p" "$RC_FILE" | grep -qxF "$RC_EXPORT"; then
        ok "already set in $RC_FILE"
    else
        # Our own block points somewhere else (e.g. VS Code was switched to/from Flatpak); fix it
        if $DRY_RUN; then
            echo -e "  ${YELLOW}[dry-run]${RESET} update CUBE_BUNDLE_PATH in $RC_FILE to \"$BUNDLE_PATH_RC\""
        else
            cp "$RC_FILE" "$RC_FILE.bak-bootstrap"
            sed -i "/^$RC_MARKER\$/,/^# <<< UBC Solar firmware <<<\$/ s|^export CUBE_BUNDLE_PATH=.*|${RC_EXPORT//&/\\&}|" "$RC_FILE"
        fi
        ok "updated CUBE_BUNDLE_PATH in $RC_FILE for $VSCODE_KIND VS Code (backup: $RC_FILE.bak-bootstrap)"
        NEEDS_NEW_SHELL=true
    fi
elif [[ -n "${CUBE_BUNDLE_PATH:-}" ]]; then
    ok "already set in your environment ($CUBE_BUNDLE_PATH)"
    [[ "$CUBE_BUNDLE_PATH" == "$BUNDLE_DIR" ]] \
        || warn "CUBE_BUNDLE_PATH is $CUBE_BUNDLE_PATH but this VS Code install uses $BUNDLE_DIR"
else
    if $DRY_RUN; then
        echo -e "  ${YELLOW}[dry-run]${RESET} append CUBE_BUNDLE_PATH=\"$BUNDLE_PATH_RC\" to $RC_FILE"
    else
        cat >>"$RC_FILE" <<EOF

$RC_MARKER
# Where the STM32Cube VS Code extension installs its bundles ($VSCODE_KIND VS Code).
# Referenced by the solar_workspace and firmware_v4 .vscode settings.
export CUBE_BUNDLE_PATH="$BUNDLE_PATH_RC"
# <<< UBC Solar firmware <<<
EOF
    fi
    ok "added export to $RC_FILE"
    NEEDS_NEW_SHELL=true
fi

# ---------------------------------------------------------------------------
# 7. STM32CubeMX
# ---------------------------------------------------------------------------
# CubeMX needs an st.com login to download, so it can't be installed here. If it's
# already installed, point the STM32 extension at it (wiki: "Absolute path to CubeMx").
step "STM32CubeMX"
if [[ -z "$CUBEMX_PATH" ]]; then
    for candidate in "${CUBEMX_CANDIDATES[@]}"; do
        [[ -x "$candidate" ]] && { CUBEMX_PATH="$candidate"; break; }
    done
fi

SETTINGS_FILE="$VSCODE_USER_DIR/settings.json"
if [[ -z "$CUBEMX_PATH" ]]; then
    warn "STM32CubeMX not found. Download it from https://www.st.com/en/development-tools/stm32cubemx (needs an ST account), run the installer, then re-run this script"
elif [[ ! -x "$CUBEMX_PATH" ]]; then
    warn "$CUBEMX_PATH is not an executable; pass the STM32CubeMX binary with --cubemx"
elif [[ "$VSCODE_KIND" == none ]]; then
    skip "found $CUBEMX_PATH; skipped VS Code setting (no VS Code)"
elif [[ -f "$SETTINGS_FILE" ]] && grep -qF "\"$CUBEMX_SETTING\"" "$SETTINGS_FILE"; then
    ok "VS Code already has a CubeMX path set"
elif $DRY_RUN; then
    echo -e "  ${YELLOW}[dry-run]${RESET} set $CUBEMX_SETTING = $CUBEMX_PATH in $SETTINGS_FILE"
else
    # settings.json may contain comments (JSONC); only edit it if it parses as plain JSON
    if python3 -I - "$SETTINGS_FILE" "$CUBEMX_SETTING" "$CUBEMX_PATH" <<'EOF'
import json, os, shutil, sys
path, key, value = sys.argv[1:]
settings = {}
if os.path.exists(path):
    with open(path) as f:
        text = f.read()
    settings = json.loads(text) if text.strip() else {}
    shutil.copy2(path, path + ".bak-bootstrap")
os.makedirs(os.path.dirname(path), exist_ok=True)
settings[key] = value
with open(path, "w") as f:
    json.dump(settings, f, indent=4)
    f.write("\n")
EOF
    then
        ok "set CubeMX path to $CUBEMX_PATH (backup: settings.json.bak-bootstrap)"
    else
        warn "couldn't edit $SETTINGS_FILE automatically; in VS Code set Settings → Extensions → STM32CubeCore → 'Absolute path to the STM32CubeMX executable' to $CUBEMX_PATH"
    fi
fi

# ---------------------------------------------------------------------------
# 8. Verify build
# ---------------------------------------------------------------------------
step "Verify toolchain (build $VERIFY_BOARD into a temp dir)"
if $SKIP_VERIFY; then
    skip "skipped (--skip-verify)"
elif $DRY_RUN; then
    skip "skipped (dry run)"
else
    missing_tools=()
    for tool in cmake ninja arm-none-eabi-gcc; do
        command -v "$tool" >/dev/null 2>&1 || missing_tools+=("$tool")
    done

    if [[ ${#missing_tools[@]} -gt 0 ]]; then
        warn "can't verify: missing ${missing_tools[*]} (re-run without --skip-apt?)"
    else
        # Build outside the repo so an existing VS Code build/ dir is never touched
        BUILD_TMP="$(mktemp -d)"
        trap 'rm -rf "$BUILD_TMP"' EXIT
        LOG="$BUILD_TMP/build.log"
        SRC="$FW_DIR/firmware/components/$VERIFY_BOARD"

        if cmake --preset Debug -S "$SRC" -B "$BUILD_TMP/build" >"$LOG" 2>&1 \
            && cmake --build "$BUILD_TMP/build" >>"$LOG" 2>&1 \
            && find "$BUILD_TMP/build" -name '*.elf' | grep -q .; then
            ok "$VERIFY_BOARD built successfully ($(arm-none-eabi-gcc -dumpversion))"
        else
            tail -n 20 "$LOG" | sed 's/^/    /'
            cp "$LOG" "$PARENT_DIR/bootstrap-build.log"
            warn "test build of $VERIFY_BOARD failed; full log: $PARENT_DIR/bootstrap-build.log"
        fi
    fi
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
step "Done"
if [[ ${#NOTES[@]} -gt 0 ]]; then
    echo -e "  ${YELLOW}Needs attention:${RESET}"
    for note in "${NOTES[@]}"; do echo "    - $note"; done
fi

echo -e "  ${BOLD}Next steps:${RESET}"
$NEEDS_RELOGIN   && echo "    - Log out and back in so the dialout group takes effect"
$NEEDS_NEW_SHELL && echo "    - Open a new terminal (or: source $RC_FILE) to pick up CUBE_BUNDLE_PATH"
echo "    - Open the workspace (restart VS Code first if it was open):"
echo "        code \"$SCRIPT_DIR/solar-workspace.code-workspace\""
echo "    - In VS Code, pick a project + configuration in the CMake panel and build"
echo "    - Build from the terminal: make -C \"$FW_DIR\" all debug"
echo "    - Telemetry (sunlink) is set up separately: see the solar_workspace README"
