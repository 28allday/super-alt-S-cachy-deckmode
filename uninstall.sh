#!/bin/bash
set -Euo pipefail

# Uninstaller for Super Alt S - Gaming Mode for KDE Plasma.
# Removes everything super-alt-s.sh installs, EXCEPT:
#   - pacman/AUR packages (steam, gamescope, drivers, ...) - offered as an
#     optional step for the two session-only AUR packages
#   - Proton-GE in ~/.local/share/Steam/compatibilitytools.d (your Steam data)
#   - video/input/wheel group memberships (commonly needed outside gaming)
#   - NVIDIA nvidia-drm.modeset=1 kernel parameter (harmless on the desktop;
#     bootloader backups from install are at *.backup.<timestamp>)
#   - the multilib pacman repo
# See README "Uninstall" for how to revert those manually.

UNINSTALL_VERSION="13.1-KDE"

ASSUME_YES=0
DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    -y|--yes) ASSUME_YES=1 ;;
    -n|--dry-run) DRY_RUN=1 ;;
    -h|--help)
      echo "Usage: ./uninstall.sh [--yes] [--dry-run]"
      echo "  --yes      don't ask for confirmation (optional steps are still skipped)"
      echo "  --dry-run  show what would be removed without changing anything"
      exit 0
      ;;
    *) echo "Unknown option: $arg (try --help)" >&2; exit 1 ;;
  esac
done

info(){ echo "[*] $*"; }
warn(){ echo "[!] $*"; }
err(){ echo "[!] $*" >&2; }

run() {
  if [[ $DRY_RUN -eq 1 ]]; then
    echo "    would run: $*"
  else
    "$@"
  fi
}

confirm() {
  local prompt="$1"
  [[ $ASSUME_YES -eq 1 ]] && return 0
  read -p "$prompt [Y/n]: " -n 1 -r
  echo
  [[ ! $REPLY =~ ^[Nn]$ ]]
}

# Optional steps default to NO and are never auto-answered by --yes.
confirm_optional() {
  local prompt="$1"
  read -p "$prompt [y/N]: " -n 1 -r
  echo
  [[ $REPLY =~ ^[Yy]$ ]]
}

if [[ $EUID -eq 0 ]]; then
  err "Run this as your normal user, not root - it needs your \$HOME for user config."
  err "It will use sudo for system files."
  exit 1
fi

# Refuse to run from inside Gaming Mode: the uninstall deletes the very
# scripts the session needs to switch back to the desktop.
if [[ -f /tmp/.gaming-session-active ]] || [[ "${XDG_CURRENT_DESKTOP:-}" == *gamescope* ]]; then
  err "You appear to be in Gaming Mode. Return to the desktop first (Super+Alt+R"
  err "or Steam > Power > Exit to Desktop), then run this again."
  exit 1
fi

# The installer only runs on KDE Plasma. If KDE isn't here, any matching
# files likely belong to a different gaming-mode tool that shares these
# filenames (e.g. DeckShift on Omarchy) - removing them would break it.
if ! command -v plasmashell >/dev/null 2>&1 && ! command -v kwin_wayland >/dev/null 2>&1; then
  warn "KDE Plasma not found on this system."
  warn "super-alt-s.sh only installs on KDE - any gaming-mode files found here"
  warn "probably belong to a different tool (e.g. DeckShift on Omarchy) and"
  warn "removing them would break it."
  if ! confirm_optional "Continue anyway?"; then
    info "Aborted - nothing was changed."
    exit 0
  fi
fi

SYSTEM_FILES=(
  # Switching + session scripts
  /usr/local/bin/switch-to-gaming
  /usr/local/bin/switch-to-desktop
  /usr/local/bin/gamescope-session-nm-wrapper
  /usr/local/bin/gaming-keybind-monitor
  /usr/local/bin/gaming-session-switch
  /usr/local/bin/gamescope-nm-start
  /usr/local/bin/gamescope-nm-stop
  /usr/local/bin/steam-library-mount
  /usr/lib/os-session-select
  /usr/local/lib/gamescope-nvidia/gamescope
  # Session + shortcut entries
  /usr/share/wayland-sessions/gamescope-session-steam-nm.desktop
  /usr/share/applications/switch-to-gaming.desktop
  # Display manager drop-ins (both DMs, plus the stale zz- name from <=12.x)
  /etc/sddm.conf.d/zzz-gaming-session.conf
  /etc/sddm.conf.d/zz-gaming-session.conf
  /etc/plasmalogin.conf.d/zzz-gaming-session.conf
  /etc/plasmalogin.conf.d/zz-gaming-session.conf
  # Sudoers
  /etc/sudoers.d/gaming-session-switch
  /etc/sudoers.d/gaming-mode-sysctl
  # Performance + audio tuning
  /etc/udev/rules.d/99-gaming-performance.rules
  /etc/security/limits.d/99-gaming-memlock.conf
  /etc/pipewire/pipewire.conf.d/10-gaming-latency.conf
  /etc/environment.d/99-shader-cache.conf
  /etc/environment.d/90-nvidia-gamescope.conf
  # Polkit
  /etc/polkit-1/rules.d/50-gamescope-networkmanager.rules
  /etc/polkit-1/rules.d/50-udisks-gaming.rules
  # NetworkManager coexistence config
  /etc/NetworkManager/conf.d/10-iwd-backend.conf
  /etc/NetworkManager/conf.d/20-unmanaged-systemd.conf
)

USER_FILES=(
  "$HOME/.config/environment.d/gamescope-session-plus.conf"
  "$HOME/.config/environment.d/90-fcitx-wayland.conf"
)

echo "=============================================="
echo " Super Alt S - Gaming Mode UNINSTALLER v$UNINSTALL_VERSION"
echo "=============================================="
echo
echo "This removes the Gaming Mode session, the Super+Alt+S shortcut, and all"
echo "system/user config installed by super-alt-s.sh. Packages, Proton-GE and"
echo "your Steam library are left alone."
[[ $DRY_RUN -eq 1 ]] && echo && echo "DRY RUN - nothing will be changed."
echo

if ! confirm "Proceed with uninstall?"; then
  info "Aborted - nothing was changed."
  exit 0
fi

# Needed even for --dry-run: file-existence checks use `sudo test` because
# /etc/sudoers.d and /etc/polkit-1/rules.d aren't world-readable.
sudo -v || { err "sudo access required"; exit 1; }

info "Stopping Gaming Mode background processes (if any)..."
run pkill -f gaming-keybind-monitor 2>/dev/null || true
run pkill -f steam-library-mount 2>/dev/null || true

info "Unmasking sleep/suspend targets (Gaming Mode masks them at runtime)..."
run sudo systemctl unmask --runtime sleep.target suspend.target hibernate.target hybrid-sleep.target 2>/dev/null || true

info "Removing system files..."
removed=0
for f in "${SYSTEM_FILES[@]}"; do
  if sudo test -e "$f" 2>/dev/null; then
    info "  removing $f"
    run sudo rm -f "$f"
    removed=$((removed+1))
  fi
done
# Directory only ever holds the NVIDIA gamescope wrapper
if sudo test -d /usr/local/lib/gamescope-nvidia 2>/dev/null; then
  run sudo rmdir --ignore-fail-on-non-empty /usr/local/lib/gamescope-nvidia
fi
info "Removed $removed system file(s)"

info "Removing user config files..."
for f in "${USER_FILES[@]}"; do
  if [[ -e "$f" ]]; then
    info "  removing $f"
    run rm -f "$f"
  fi
done

# Remove the Super+Alt+S shortcut section from KDE's global shortcuts
shortcuts_file="$HOME/.config/kglobalshortcutsrc"
if [[ -f "$shortcuts_file" ]] && grep -q '^\[switch-to-gaming\.desktop\]' "$shortcuts_file"; then
  info "Removing Super+Alt+S shortcut from kglobalshortcutsrc..."
  if [[ $DRY_RUN -eq 1 ]]; then
    echo "    would remove [switch-to-gaming.desktop] section from $shortcuts_file"
  else
    tmp_shortcuts=$(mktemp)
    awk 'BEGIN{skip=0} /^\[/{skip=($0=="[switch-to-gaming.desktop]")} !skip' \
      "$shortcuts_file" > "$tmp_shortcuts" && mv "$tmp_shortcuts" "$shortcuts_file"
  fi
fi

# Restore the KDE Screen Reader shortcut the installer cleared - only if it
# still holds the exact value we wrote, so user customisations are untouched.
if [[ -f "$shortcuts_file" ]] && grep -q 'Toggle Screen Reader On and Off=none,none,' "$shortcuts_file"; then
  info "Restoring default Screen Reader shortcut (Meta+Alt+S)..."
  run sed -i 's|Toggle Screen Reader On and Off=none,none,|Toggle Screen Reader On and Off=Meta+Alt+S,Meta+Alt+S,|' "$shortcuts_file"
fi

# Tell KDE to reload shortcuts if it's running
if [[ $DRY_RUN -eq 0 ]]; then
  command -v dbus-send >/dev/null 2>&1 && \
    dbus-send --type=signal --dest=org.kde.kglobalaccel /kglobalaccel org.kde.KGlobalAccel.yourShortcutsChanged 2>/dev/null || true
fi

info "Reloading udev rules..."
run sudo udevadm control --reload-rules 2>/dev/null || true

info "Restarting polkit to drop removed rules..."
run sudo systemctl restart polkit.service 2>/dev/null || true

run rm -f /tmp/.gaming-session-active

# Optional: the two AUR packages that exist only for this Gaming Mode.
# steam/gamescope/mangohud/gamemode/drivers are useful on their own, so they
# are never offered for removal here.
session_pkgs=()
for pkg in gamescope-session-git gamescope-session-steam-git; do
  pacman -Qi "$pkg" &>/dev/null && session_pkgs+=("$pkg")
done
if [[ ${#session_pkgs[@]} -gt 0 && $DRY_RUN -eq 0 ]]; then
  echo
  echo "The following AUR packages were installed only for Gaming Mode:"
  printf '    - %s\n' "${session_pkgs[@]}"
  if confirm_optional "Remove them now with pacman -Rns?"; then
    sudo pacman -Rns "${session_pkgs[@]}" || warn "Package removal failed - remove manually with: sudo pacman -Rns ${session_pkgs[*]}"
  else
    info "Keeping packages (remove later with: sudo pacman -Rns ${session_pkgs[*]})"
  fi
fi

# Optional: the autologin group membership added for SDDM session switching.
if groups 2>/dev/null | grep -qw autologin && [[ $DRY_RUN -eq 0 ]]; then
  echo
  if confirm_optional "Remove $USER from the 'autologin' group (added for SDDM session switching)?"; then
    sudo gpasswd -d "$USER" autologin || warn "Failed - remove manually with: sudo gpasswd -d $USER autologin"
  fi
fi

# Optional: the Gaming Mode config file, if one was created.
for conf in /etc/gaming-mode.conf "$HOME/.gaming-mode.conf"; do
  if [[ -f "$conf" && $DRY_RUN -eq 0 ]]; then
    if confirm_optional "Remove config file $conf?"; then
      sudo rm -f "$conf"
    fi
  fi
done

echo
echo "=============================================="
echo " Uninstall complete"
echo "=============================================="
echo
echo "Left in place (see README 'Uninstall' for how to revert):"
echo "  - Packages: steam, gamescope, mangohud, gamemode, Vulkan drivers, python-evdev"
echo "  - Proton-GE in ~/.local/share/Steam/compatibilitytools.d/"
echo "  - Group memberships: video, input, wheel"
echo "  - NVIDIA only: nvidia-drm.modeset=1 kernel parameter"
echo "  - The [multilib] pacman repo"
echo
echo "NetworkManager's stock config is restored - if you use NetworkManager as"
echo "your main network service, restart it: sudo systemctl restart NetworkManager"
echo
echo "Log out and back in (or reboot) to finish - this clears session"
echo "environment variables and refreshes the login screen's session list."
