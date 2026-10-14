#!/usr/bin/env bash
# Bootstrap a UBC Solar firmware development environment (Ubuntu only).
#
# Sets up the team repos next to this solar_workspace folder, with firmware_v4 ready to build:
#   1. Installs the build toolchain (same packages as firmware_v4 CI) + Ruby for Ceedling
#   2. Installs ST-LINK udev rules and adds you to the dialout group
#   3. Clones firmware_v4, sunlink, sunlite and solar_tools (each skipped if already
#      present) and installs firmware_v4's git hooks
#   4. Sets CUBE_BUNDLE_PATH for the STM32Cube VS Code extension
#   5. Installs the STM32Cube + CMake Tools VS Code extensions
#   6. Verifies the toolchain by building one board into a temporary directory
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
VERIFY_BOARD="tel"

# Cloned as siblings of solar_workspace. Only firmware_v4 gets further setup;
# the rest are just cloned (see each repo's README for its own setup).
REPOS=("$FW_REPO" sunlink sunlite solar_tools)

APT_PACKAGES=(
    git make cmake ninja-build              # build system
    gcc-arm-none-eabi libnewlib-arm-none-eabi  # ARM toolchain (matches firmware_v4 CI)
    ruby                                    # runs the vendored Ceedling in firmware_v4/tools/ceedling
    stlink-tools                            # st-flash/st-info + ST-LINK udev rules
)

VSCODE_EXTENSIONS=(
    stmicroelectronics.stm32-vscode-extension  # STM32Cube for VS Code (pulls in the stm32cube-ide-* pack)
    ms-vscode.cmake-tools
)

DEFAULT_CUBE_BUNDLE_PATH="\$HOME/.local/share/stm32cube/bundles"
RC_FILE="$HOME/.bashrc"
RC_MARKER="# >>> UBC Solar firmware >>>"

USE_SSH=false
SKIP_APT=false
SKIP_VERIFY=false
DRY_RUN=false

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
  --ssh           Clone over SSH (git@github.com:...) instead of HTTPS
  --skip-apt      Don't install system packages (no sudo needed for the rest)
  --skip-verify   Don't test-build firmware at the end
  --dry-run       Print what would be done without changing anything
  -h, --help      Show this help
EOF
}

# ---------------------------------------------------------------------------
# Args + preflight
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --ssh)         USE_SSH=true ;;
        --skip-apt)    SKIP_APT=true ;;
        --skip-verify) SKIP_VERIFY=true ;;
        --dry-run)     DRY_RUN=true ;;
        -h|--help)     usage; exit 0 ;;
        *)             usage; die "unknown option: $1" ;;
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
# 1. System packages
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

FW_DIR="$PARENT_DIR/$FW_REPO"
if ! $DRY_RUN || [[ -d "$FW_DIR/.git" ]]; then
    if [[ "$(git -C "$FW_DIR" config --get core.hooksPath 2>/dev/null || true)" == ".githooks" ]]; then
        ok "git hooks already installed"
    else
        run make -C "$FW_DIR" --no-print-directory hooks
        ok "git hooks installed (branch naming checks)"
    fi
fi

# ---------------------------------------------------------------------------
# 4. CUBE_BUNDLE_PATH
# ---------------------------------------------------------------------------
step "CUBE_BUNDLE_PATH"
if grep -qF "$RC_MARKER" "$RC_FILE" 2>/dev/null; then
    ok "already set in $RC_FILE"
elif [[ -n "${CUBE_BUNDLE_PATH:-}" ]]; then
    ok "already set in your environment ($CUBE_BUNDLE_PATH)"
else
    if $DRY_RUN; then
        echo -e "  ${YELLOW}[dry-run]${RESET} append CUBE_BUNDLE_PATH export to $RC_FILE"
    else
        cat >>"$RC_FILE" <<EOF

$RC_MARKER
# Where the STM32Cube VS Code extension installs its toolchain bundles.
# Referenced by solar_workspace and firmware_v4 .vscode settings.
export CUBE_BUNDLE_PATH="$DEFAULT_CUBE_BUNDLE_PATH"
# <<< UBC Solar firmware <<<
EOF
    fi
    ok "added export to $RC_FILE"
    NEEDS_NEW_SHELL=true
fi

# ---------------------------------------------------------------------------
# 5. VS Code extensions
# ---------------------------------------------------------------------------
step "VS Code extensions"
if ! command -v code >/dev/null 2>&1; then
    warn "VS Code ('code') not found; install it from https://code.visualstudio.com and re-run"
else
    installed="$(code --list-extensions 2>/dev/null | tr '[:upper:]' '[:lower:]')"
    for ext in "${VSCODE_EXTENSIONS[@]}"; do
        if grep -qx "${ext,,}" <<<"$installed"; then
            ok "$ext already installed"
        else
            run code --install-extension "$ext" --force >/dev/null 2>&1
            ok "installed $ext"
        fi
    done
fi

# ---------------------------------------------------------------------------
# 6. Verify build
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
echo "    - Open the workspace:"
echo "        code \"$SCRIPT_DIR/solar-workspace.code-workspace\""
echo "    - On first open, let the STM32Cube extension download its toolchain bundles"
echo "    - Build from the terminal: make -C \"$FW_DIR\" all debug"
