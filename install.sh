#!/usr/bin/env bash
#
# install.sh - Bootstrap a fresh Arch Linux install for this niri setup.
#
#   1. Installs yay (AUR helper) if it is not already installed
#   2. Installs every package listed in packages.txt
#
# Packages are installed with yay, which resolves official-repo packages
# through pacman and builds the AUR-only ones (wayle, wlogout,
# zen-browser-bin) automatically.
#
# Usage: ./install.sh

set -euo pipefail

# --- Output helpers ----------------------------------------------------------

info()  { printf '\033[1;34m::\033[0m %s\n' "$*"; }
error() { printf '\033[1;31m::\033[0m %s\n' "$*" >&2; exit 1; }

# --- Sanity checks -----------------------------------------------------------

# makepkg (and therefore building yay) refuses to run as root.
if [[ $EUID -eq 0 ]]; then
    error "Do not run this script as root. Run it as a normal user with sudo access."
fi

if ! command -v pacman &>/dev/null; then
    error "pacman not found - this script only works on Arch Linux and derivatives."
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
PACKAGES_FILE="$SCRIPT_DIR/packages.txt"

[[ -f "$PACKAGES_FILE" ]] || error "packages.txt not found at $PACKAGES_FILE"

# Clean up the yay build directory on exit, whatever happens.
BUILD_DIR=""
cleanup() {
    if [[ -n "$BUILD_DIR" && -d "$BUILD_DIR" ]]; then
        rm -rf "$BUILD_DIR"
    fi
}
trap cleanup EXIT

# --- Step 1: Install yay -----------------------------------------------------

if command -v yay &>/dev/null; then
    info "yay is already installed - skipping build."
else
    info "Installing prerequisites (base-devel, git)..."
    sudo pacman -S --needed --noconfirm base-devel git

    info "Building yay from the AUR..."
    BUILD_DIR="$(mktemp -d)"
    git clone https://aur.archlinux.org/yay.git "$BUILD_DIR/yay"
    (cd "$BUILD_DIR/yay" && makepkg -si --noconfirm)
    rm -rf "$BUILD_DIR"
    BUILD_DIR=""

    command -v yay &>/dev/null || error "yay installation failed."
    info "yay installed successfully."
fi

# --- Step 2: Read packages.txt -----------------------------------------------
# Strip comments (# ...) and blank lines, then read one package per line.

info "Reading package list from $PACKAGES_FILE..."

mapfile -t PACKAGES < <(
    sed -e 's/#.*//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "$PACKAGES_FILE" \
        | grep -v '^$'
)

if [[ ${#PACKAGES[@]} -eq 0 ]]; then
    error "No packages found in $PACKAGES_FILE"
fi

info "Installing ${#PACKAGES[@]} packages:"
printf '    %s\n' "${PACKAGES[@]}"

# --- Step 3: Install packages ------------------------------------------------
# --needed skips packages that are already up to date, so this script can be
# re-run safely. yay pulls official-repo packages via pacman and builds the
# AUR ones.

info "Installing packages with yay..."
yay -S --needed --noconfirm "${PACKAGES[@]}"

info "All packages installed."

# Optional: enable the services some of these packages provide.
# Uncomment the ones you want on a fresh install:
#
#   sudo systemctl enable --now NetworkManager
#   sudo systemctl enable --now bluetooth
#   systemctl --user enable --now pipewire pipewire-pulse wireplumber
