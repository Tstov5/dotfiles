#!/usr/bin/env bash
#
# install.sh - Bootstrap a fresh Arch Linux install for this niri setup.
#
#   0. Deploys the dotfiles: renames the cloned "dotfiles" directory to ".config"
#      (equivalent to `mv dotfiles .config`), so you only need to clone, cd, and
#      run this script.
#   1. Syncs NTP clock, refreshes the Arch keyring, and configures GPG
#      keyservers for pacman-key and makepkg
#   2. Installs yay (AUR helper) if it is not already installed
#   3. Reads the package list from packages.txt
#   3b. Pre-imports GPG keys required by AUR packages with signed sources
#   4. Installs every package listed in packages.txt via yay
#   5. Enables the ly display manager (starts on next boot)
#   6. Installs the Cline CLI via npm (after nodejs/npm above)
#   7. Reboots the system (only if every step completed without errors)
#
# Packages are installed with yay, which resolves official-repo packages
# through pacman and handles the AUR ones (wayle-bin, wlogout, localsend,
# shelly, zen-browser-bin) automatically.
#
# Usage: ./install.sh [--no-reboot]

set -euo pipefail

# --- Output helpers ----------------------------------------------------------

info()  { printf '\033[1;34m::\033[0m %s\n' "$*"; }
error() { printf '\033[1;31m::\033[0m %s\n' "$*" >&2; exit 1; }

# --- Options -----------------------------------------------------------------

REBOOT=true
while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-reboot)
            REBOOT=false
            shift
            ;;
        -h|--help)
            info "Usage: install.sh [--no-reboot]"
            info "Installs all packages and configuration for the dotfiles."
            info "On success the system reboots automatically unless --no-reboot is given."
            exit 0
            ;;
        *)
            error "Unknown argument: $1 (use -h or --help for usage)"
            ;;
    esac
done

# --- Sanity checks -----------------------------------------------------------

# makepkg (and therefore building yay) refuses to run as root.
if [[ $EUID -eq 0 ]]; then
    error "Do not run this script as root. Run it as a normal user with sudo access."
fi

if ! command -v pacman &>/dev/null; then
    error "pacman not found - this script only works on Arch Linux and derivatives."
fi

# --- Step 0: Deploy the dotfiles into ~/.config --------------------------------
# A fresh clone lands in a directory literally called "dotfiles". Rename it to
# ".config" (mirroring `mv dotfiles .config`) so the repo contents land where
# applications expect them — this means you only have to clone and run this
# script. Bash has already read the script off disk, so renaming its own
# directory mid-run is safe; we then just re-point SCRIPT_DIR at the new path.
# If the directory is already named ".config" this whole block is a no-op,
# which keeps the script safe to re-run.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
REPO_NAME="$(basename "$SCRIPT_DIR")"

if [[ "$REPO_NAME" == "dotfiles" ]]; then
    REPO_PARENT="$(dirname "$SCRIPT_DIR")"
    TARGET="$REPO_PARENT/.config"

    if [[ -e "$TARGET" ]]; then
        error "A '.config' already exists at $TARGET. Move it aside first, or rename the repo by hand: mv dotfiles .config"
    fi

    info "Deploying dotfiles: renaming '$REPO_NAME' -> '.config'"
    mv -- "$SCRIPT_DIR" "$TARGET" || error "Failed to rename '$REPO_NAME' to '.config'"
    SCRIPT_DIR="$TARGET"
fi

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

# --- Step 1: Sync clock, refresh keyring, configure keyservers -----------------
# Three things that commonly break package/key imports on a fresh Arch ISO:
#   1. Clock drift → TLS cert failures → keyserver connection errors
#   2. Stale archlinux-keyring → "unknown trust" signature errors
#   3. No GPG keyserver configured → "keyserver receive failed: Server
#      indicated a failure" when makepkg builds AUR packages


# Sync the system clock. A wrong clock breaks TLS connections to keyservers.
# On a fresh Arch ISO install, systemd-timesyncd may not have synced yet.
info "Synchronizing system clock via NTP..."
if command -v timedatectl &>/dev/null; then
    sudo timedatectl set-ntp true || info "NTP sync failed - continuing"
    for _ in {1..10}; do
        if timedatectl show -p NTPSynchronized --value 2>/dev/null | grep -qi yes; then
            break
        fi
        sleep 1
    done
    timedatectl status || true
else
    info "timedatectl not found - skipping NTP sync (install systemd for time sync)."
fi

info "Refreshing the Arch keyring..."
if ! sudo pacman -Sy --needed --noconfirm archlinux-keyring; then
    info "Initializing the pacman keyring and retrying..."
    sudo pacman-key --init
    sudo pacman-key --populate archlinux
    sudo pacman -Sy --needed --noconfirm archlinux-keyring
fi

# Configure the keyserver for the pacman keyring (used by pacman-key).
info "Configuring pacman keyring keyserver..."
sudo mkdir -p /etc/pacman.d/gnupg
cat <<'EOF' | sudo tee /etc/pacman.d/gnupg/gpg.conf > /dev/null
keyserver hkp://keyserver.ubuntu.com:80
keyserver-options auto-key-locate nodefault
EOF

# Refresh all known keys from the keyserver (with retry for flaky connections).
info "Refreshing pacman keys..."
for attempt in 1 2 3; do
    if sudo pacman-key --refresh-keys; then
        break
    fi
    info "pacman-key refresh attempt $attempt failed, retrying..."
    sleep 2
done
info "Key refresh complete (non-fatal if some keys could not be refreshed)."

# Configure the user GPG keyring (~/.gnupg) so makepkg can fetch keys.
info "Configuring user GPG keyserver for AUR package builds..."
GNUPGHOME="$HOME/.gnupg"
mkdir -p "$GNUPGHOME"
chmod 700 "$GNUPGHOME"

cat > "$GNUPGHOME/gpg.conf" <<'EOF'
keyserver hkp://keyserver.ubuntu.com:80
keyserver-options auto-key-locate nodefault
keyserver-options auto-key-retrieve
EOF

cat > "$GNUPGHOME/dirmngr.conf" <<'EOF'
keyserver hkp://keyserver.ubuntu.com:80
EOF

# Restart dirmngr so it picks up the new keyserver configuration.
gpgconf --kill dirmngr 2>/dev/null || true
gpgconf --launch dirmngr 2>/dev/null || true

# --- Step 2: Install yay -----------------------------------------------------

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

# --- Step 3: Read packages.txt -----------------------------------------------
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

# --- Step 3b: Pre-import GPG keys for AUR packages with signed sources ---------
# If the key is absent, makepkg's auto-fetch from keyservers often fails with
# "keyserver receive failed: Server indicated a failure". We import explicitly
# via port 80 (bypasses common firewall blocks), falling back to GitHub .gpg.
#
# Format: "KEYID:GITHUB_USER"
AUR_PGP_KEYS=(
    "F4FDB18A9937358364B276E9E25D679AF73C6D2F:ArtsyMacaw"  # wlogout
)

for entry in "${AUR_PGP_KEYS[@]}"; do
    keyid="${entry%%:*}"
    gh_user="${entry##*:}"

    if gpg --list-keys "$keyid" &>/dev/null 2>&1; then
        info "GPG key $keyid already present - skipping."
        continue
    fi

    info "Importing GPG key $keyid (required by AUR package builds)..."
    if ! gpg --batch --keyserver hkp://keyserver.ubuntu.com:80 --recv-keys "$keyid"; then
        info "Keyserver import failed for $keyid — falling back to GitHub..."
        if ! curl -sSL "https://github.com/${gh_user}.gpg" | gpg --batch --import; then
            info "Could not import GPG key $keyid — builds requiring it may fail."
            info "Try importing it manually: gpg --keyserver hkp://keyserver.ubuntu.com:80 --recv-keys $keyid"
        fi
    fi
done

# --- Step 4: Install packages ------------------------------------------------
# --needed skips packages that are already up to date, so this script can be
# re-run safely. yay pulls official-repo packages via pacman and builds the
# AUR ones.

info "Installing packages with yay..."
yay -S --needed --noconfirm "${PACKAGES[@]}"

info "All packages installed."

# --- Step 5: Enable the ly display manager -----------------------------------
# ly provides the TUI login screen and starts niri from the session files in
# /usr/share/wayland-sessions. The ly package ships a template service
# (ly@.service) that must be started on a specific TTY — the conventional
# choice is TTY2, leaving TTY1 for a manual getty/console login.
#
# Only one display manager can be enabled at a time (they all claim the
# display-manager.service alias), so enabling ly fails if another display
# manager (gdm, sddm, ...) is already enabled.

LY_SERVICE="ly@tty2.service"

if systemctl is-enabled --quiet "$LY_SERVICE"; then
    info "ly is already enabled on $LY_SERVICE - skipping."
else
    info "Enabling ly on $LY_SERVICE (it will start on the next boot)..."
    sudo systemctl enable "$LY_SERVICE" \
        || error "Could not enable ly - another display manager may be enabled. Disable it first: sudo systemctl disable <name>"
fi

# Enable polkit daemon (needed by shelly's GUI for privileged operations).
if systemctl is-enabled --quiet polkit.service 2>/dev/null; then
    info "polkit is already enabled - skipping."
else
    info "Enabling polkit daemon..."
    sudo systemctl enable --now polkit.service || info "Could not enable polkit - some GUI apps may not work."
fi

# Optional: enable the services some of these packages provide.
# Uncomment the ones you want on a fresh install:
#
#   sudo systemctl enable --now NetworkManager
#   sudo systemctl enable --now bluetooth
#   systemctl --user enable --now pipewire pipewire-pulse wireplumber

# --- Step 6: Install the Cline CLI ---------------------------------------------
# Cline is an AI coding agent that runs in your terminal. It is distributed as an
# npm package and requires Node.js 20+ (the nodejs/npm packages installed in
# Step 4 provide that). Official install guide:
# https://docs.cline.bot/getting-started/installing-cline
#     npm install -g cline
#
# On Arch, `npm install -g` writes into /usr, so sudo is required. This step is
# safe to re-run: if `cline` is already on PATH we skip the install.

if ! command -v npm &>/dev/null; then
    error "npm not found - the nodejs/npm packages should have been installed in Step 4."
fi

if command -v cline &>/dev/null; then
    info "cline is already installed at $(command -v cline) - skipping."
else
    info "Installing the Cline CLI (npm install -g cline)..."
    sudo npm install -g cline
    command -v cline &>/dev/null || error "cline installation failed."
    info "cline installed at $(command -v cline)"
fi

# --- Step 7: Reboot on success ------------------------------------------------
# This script runs with `set -euo pipefail`, so any command that fails exits
# the script immediately with a non-zero status. Reaching this point therefore
# means every step completed without errors. Reboot so newly enabled services
# (e.g. ly) and any kernel updates take full effect.
# Pass --no-reboot to skip the restart.

if [[ "$REBOOT" == true ]]; then
    info "All steps completed successfully — no errors detected."
    info "Rebooting in 10 seconds... (press Ctrl+C to cancel the reboot)"
    sleep 10
    info "Rebooting now."
    sudo systemctl reboot
else
    info "All steps completed successfully, but --no-reboot was given - skipping reboot."
fi
