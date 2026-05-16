#!/bin/bash
set -Euo pipefail

Super_Shift_S_VERSION="12.27-KDE"

CONFIG_FILE="/etc/gaming-mode.conf"
[[ -f "$HOME/.gaming-mode.conf" ]] && CONFIG_FILE="$HOME/.gaming-mode.conf"
# shellcheck source=/dev/null
source "$CONFIG_FILE" 2>/dev/null || true
: "${PERFORMANCE_MODE:=enabled}"

NEEDS_RELOGIN=0
NEEDS_REBOOT=0

info(){ echo "[*] $*"; }
warn(){ echo "[!] $*"; }
err(){ echo "[!] $*" >&2; }

die() {
  local msg="$1"; local code="${2:-1}"
  echo "FATAL: $msg" >&2
  logger -t gaming-mode "Installation failed: $msg"
  exit "$code"
}

check_aur_helper_functional() {
  local helper="$1"
  if $helper --version &>/dev/null; then
    return 0
  else
    return 1
  fi
}

rebuild_yay() {
  info "Attempting to rebuild yay..."
  local tmp_dir
  tmp_dir=$(mktemp -d)
  pushd "$tmp_dir" >/dev/null || return 1
  if git clone https://aur.archlinux.org/yay.git && cd yay && makepkg -si --noconfirm; then
    popd >/dev/null || true
    rm -rf "$tmp_dir"
    info "yay rebuilt successfully"
    return 0
  else
    popd >/dev/null || true
    rm -rf "$tmp_dir"
    err "Failed to rebuild yay"
    return 1
  fi
}

validate_environment() {
  command -v pacman  >/dev/null || die "pacman required"
  if ! command -v plasmashell >/dev/null 2>&1 && ! command -v kwin_wayland >/dev/null 2>&1; then
    die "KDE Plasma not found (plasmashell/kwin_wayland required)"
  fi
  [ -d "$HOME/.config" ] || mkdir -p "$HOME/.config"
}

check_package() { pacman -Qi "$1" &>/dev/null; }

is_amd_igpu_card() {
  local card_path="$1"
  local device_path="$card_path/device"
  local pci_slot=""
  [[ -L "$device_path" ]] && pci_slot=$(basename "$(readlink -f "$device_path")")
  [[ -z "$pci_slot" ]] && return 1
  local device_info
  device_info=$(/usr/bin/lspci -s "$pci_slot" 2>/dev/null)
  if echo "$device_info" | grep -iqE 'renoir|cezanne|barcelo|rembrandt|phoenix|raphael|lucienne|picasso|raven|vega.*mobile|vega.*integrated|radeon.*graphics|yellow.*carp|green.*sardine|cyan.*skillfish|vangogh|van gogh|mendocino|hawk.*point|strix.*point|strix.*halo|krackan|sarlak'; then
    return 0
  fi
  if echo "$device_info" | grep -iqE 'radeon rx|navi [0-9]|navi[0-9]|vega 56|vega 64|radeon vii|radeon pro|firepro|polaris|ellesmere|baffin|lexa|radeon [0-9]{3,4}[^0-9]'; then
    return 1
  fi
  return 1
}

check_intel_only() {
  local card_name driver driver_link
  local has_intel=false
  local has_amd_nvidia=false

  for card_path in /sys/class/drm/card[0-9]*; do
    card_name=$(basename "$card_path")
    [[ "$card_name" == render* ]] && continue
    driver_link="$card_path/device/driver"
    [[ -L "$driver_link" ]] || continue
    driver=$(basename "$(readlink "$driver_link")")

    case "$driver" in
      i915|xe)
        has_intel=true
        ;;
      nvidia|amdgpu)
        has_amd_nvidia=true
        ;;
    esac
  done

  if $has_intel && ! $has_amd_nvidia; then
    return 0
  fi
  return 1
}

detect_dgpu_monitors() {
  local -n _monitors=$1
  local -n _dgpu_card=$2
  local -n _dgpu_type=$3
  _monitors=()
  _dgpu_card=""
  _dgpu_type=""

  local lspci_output
  lspci_output=$(/usr/bin/lspci 2>/dev/null)
  if echo "$lspci_output" | grep -qi nvidia; then
    _dgpu_type="NVIDIA"
  elif echo "$lspci_output" | grep -iqE 'radeon rx|navi|vega 56|vega 64|radeon vii|radeon pro'; then
    _dgpu_type="AMD dGPU"
  fi

  for card_path in /sys/class/drm/card[0-9]*; do
    local card_name
    card_name=$(basename "$card_path")
    [[ "$card_name" == render* ]] && continue
    local driver_link="$card_path/device/driver"
    [[ -L "$driver_link" ]] || continue
    local driver
    driver=$(basename "$(readlink "$driver_link")")
    local is_dgpu=false

    case "$driver" in
      nvidia)
        is_dgpu=true
        [[ -z "$_dgpu_type" ]] && _dgpu_type="NVIDIA"
        ;;
      amdgpu)
        if ! is_amd_igpu_card "$card_path"; then
          is_dgpu=true
          [[ -z "$_dgpu_type" ]] && _dgpu_type="AMD dGPU"
        fi
        ;;
    esac

    if $is_dgpu; then
      _dgpu_card="$card_name"
      for connector in "$card_path"/"$card_name"-*/status; do
        [[ -f "$connector" ]] || continue
        local conn_dir
        conn_dir=$(dirname "$connector")
        local conn_name
        conn_name=$(basename "$conn_dir")
        conn_name=${conn_name#card*-}
        [[ "$conn_name" == Writeback* ]] && continue
        local status
        status=$(cat "$connector" 2>/dev/null)
        if [[ "$status" == "connected" ]]; then
          local resolution=""
          local mode_file="$conn_dir/modes"
          [[ -f "$mode_file" ]] && [[ -s "$mode_file" ]] && resolution=$(head -1 "$mode_file" 2>/dev/null)
          _monitors+=("$conn_name|$resolution")
        fi
      done
      break
    fi
  done
}

check_nvidia_kernel_params() {
  local lspci_output
  lspci_output=$(/usr/bin/lspci 2>/dev/null)
  if ! echo "$lspci_output" | grep -qi nvidia; then
    return 0
  fi

  echo ""
  echo "================================================================"
  echo "  NVIDIA KERNEL PARAMETER CHECK"
  echo "================================================================"
  echo ""

  if grep -qE "nvidia[-_]drm\.modeset=1" /proc/cmdline 2>/dev/null; then
    info "nvidia-drm.modeset=1 is already configured"
    return 0
  fi

  warn "nvidia-drm.modeset=1 is NOT SET - required for Gaming Mode!"
  echo ""

  local bootloader=""
  local config_file=""

  # Check /etc/default/limine first: it's readable by the user and is the
  # source-of-truth on CachyOS/limine-mkinitcpio-hook installs. The ESP
  # (/boot) is typically mounted with fmask=0077, so `[ -f /boot/limine.conf ]`
  # returns false for non-root even when the file exists.
  if [[ -f /etc/default/limine ]] || command -v limine-update >/dev/null 2>&1; then
    bootloader="limine"
    if sudo test -f /boot/limine.conf 2>/dev/null; then
      config_file="/boot/limine.conf"
    elif sudo test -f /boot/limine/limine.conf 2>/dev/null; then
      config_file="/boot/limine/limine.conf"
    else
      config_file="/boot/limine.conf"
    fi
  elif sudo test -f /boot/limine.conf 2>/dev/null; then
    bootloader="limine"; config_file="/boot/limine.conf"
  elif sudo test -f /boot/limine/limine.conf 2>/dev/null; then
    bootloader="limine"; config_file="/boot/limine/limine.conf"
  elif sudo test -d /boot/loader/entries 2>/dev/null; then
    bootloader="systemd-boot"
  elif [ -f /etc/default/grub ]; then
    bootloader="grub"
  fi

  info "Detected bootloader: $bootloader"

  case "$bootloader" in
    limine)
      info "Limine config: $config_file"
      read -p "Add nvidia-drm.modeset=1 to Limine config? [Y/n]: " -n 1 -r
      echo
      if [[ ! $REPLY =~ ^[Nn]$ ]]; then
        configure_limine_nvidia "$config_file"
      else
        warn "Skipping - you'll need to add nvidia-drm.modeset=1 manually"
        show_manual_nvidia_instructions
      fi
      ;;
    systemd-boot)
      echo ""
      read -p "Add nvidia-drm.modeset=1 to systemd-boot entries? [Y/n]: " -n 1 -r
      echo
      if [[ ! $REPLY =~ ^[Nn]$ ]]; then
        configure_systemd_boot_nvidia
      else
        warn "Skipping - you'll need to add nvidia-drm.modeset=1 manually"
        show_manual_nvidia_instructions
      fi
      ;;
    grub)
      echo ""
      read -p "Add nvidia-drm.modeset=1 to GRUB config? [Y/n]: " -n 1 -r
      echo
      if [[ ! $REPLY =~ ^[Nn]$ ]]; then
        configure_grub_nvidia
      else
        warn "Skipping - you'll need to add nvidia-drm.modeset=1 manually"
        show_manual_nvidia_instructions
      fi
      ;;
    *)
      echo ""
      warn "Could not detect bootloader type"
      show_manual_nvidia_instructions
      ;;
  esac
}

configure_limine_nvidia() {
  local config_file="$1"

  # CachyOS (and the standard limine-mkinitcpio-hook setup) regenerates
  # /boot/limine.conf from /etc/default/limine on every mkinitcpio run, so a
  # direct edit of limine.conf would be wiped on the next kernel update.
  # Detect that setup and edit the source of truth instead.
  if [[ -f /etc/default/limine ]] && command -v limine-update >/dev/null 2>&1; then
    info "Detected limine-mkinitcpio-hook (CachyOS-style); editing /etc/default/limine"

    sudo cp /etc/default/limine "/etc/default/limine.backup.$(date +%Y%m%d%H%M%S)" || {
      err "Failed to backup /etc/default/limine"
      return 1
    }

    if grep -qE '^KERNEL_CMDLINE\[default\].*nvidia-drm\.modeset=1' /etc/default/limine; then
      info "nvidia-drm.modeset=1 already present in /etc/default/limine"
    else
      # Append nvidia-drm.modeset=1 inside the existing KERNEL_CMDLINE[default] quotes.
      # The CachyOS default looks like:  KERNEL_CMDLINE[default]+="quiet ... root=UUID=..."
      if sudo sed -i -E '/^KERNEL_CMDLINE\[default\][[:space:]]*\+?=/ s/"[[:space:]]*$/ nvidia-drm.modeset=1"/' /etc/default/limine \
         && grep -qE '^KERNEL_CMDLINE\[default\].*nvidia-drm\.modeset=1' /etc/default/limine; then
        info "Added nvidia-drm.modeset=1 to /etc/default/limine"
      else
        err "Failed to patch /etc/default/limine — please add nvidia-drm.modeset=1 to KERNEL_CMDLINE[default] manually"
        show_manual_nvidia_instructions
        return 1
      fi
    fi

    info "Regenerating Limine config via limine-update..."
    if sudo limine-update; then
      echo ""
      echo "  Limine config updated and regenerated"
      echo "  Changes will take effect after reboot"
      echo ""
      NEEDS_REBOOT=1
    else
      err "limine-update failed — please run 'sudo limine-update' manually"
      show_manual_nvidia_instructions
    fi
    return
  fi

  # Fallback: direct edit (vanilla Limine without the mkinitcpio hook).
  info "Backing up Limine config..."
  sudo cp "$config_file" "${config_file}.backup.$(date +%Y%m%d%H%M%S)" || {
    err "Failed to backup Limine config"
    return 1
  }

  info "Adding nvidia-drm.modeset=1 to Limine cmdline..."

  if sudo sed -i '/^[[:space:]]*cmdline:/ s/$/ nvidia-drm.modeset=1/' "$config_file"; then
    if grep -q "nvidia-drm.modeset=1" "$config_file"; then
      info "Successfully added nvidia-drm.modeset=1 to Limine config"
      echo ""
      echo "  Limine config updated"
      echo "  Changes will take effect after reboot"
      echo ""
      NEEDS_REBOOT=1
    else
      err "Failed to add parameter - please add manually"
      show_manual_nvidia_instructions
    fi
  else
    err "Failed to modify Limine config"
    show_manual_nvidia_instructions
  fi
}

configure_grub_nvidia() {
  local grub_default="/etc/default/grub"

  info "Backing up GRUB config..."
  sudo cp "$grub_default" "${grub_default}.backup.$(date +%Y%m%d%H%M%S)" || {
    err "Failed to backup GRUB config"
    return 1
  }

  info "Adding nvidia-drm.modeset=1 to GRUB..."

  if ! grep -q "nvidia-drm.modeset=1" "$grub_default"; then
    # Handle both single-quoted and double-quoted GRUB_CMDLINE_LINUX_DEFAULT
    sudo sed -i -E "s/(GRUB_CMDLINE_LINUX_DEFAULT=['\"][^'\"]*)/\1 nvidia-drm.modeset=1/" "$grub_default"

    if grep -q "nvidia-drm.modeset=1" "$grub_default"; then
      info "Regenerating GRUB config..."
      sudo grub-mkconfig -o /boot/grub/grub.cfg || {
        err "Failed to regenerate GRUB config"
        return 1
      }
      info "Successfully configured GRUB for NVIDIA"
      NEEDS_REBOOT=1
    else
      err "Failed to add parameter to GRUB"
      show_manual_nvidia_instructions
    fi
  fi
}

configure_systemd_boot_nvidia() {
  local entries_dir="/boot/loader/entries"

  if ! sudo test -d "$entries_dir" 2>/dev/null; then
    err "systemd-boot entries directory not found at $entries_dir"
    show_manual_nvidia_instructions
    return 1
  fi

  local -a entry_files=()
  while IFS= read -r -d '' f; do
    entry_files+=("$f")
  done < <(sudo find "$entries_dir" -name "*.conf" -print0 2>/dev/null)

  if [[ ${#entry_files[@]} -eq 0 ]]; then
    err "No boot entries found in $entries_dir"
    show_manual_nvidia_instructions
    return 1
  fi

  info "Found ${#entry_files[@]} boot entry/entries:"
  for entry in "${entry_files[@]}"; do
    echo "    - $(basename "$entry")"
  done
  echo ""

  local modified=0

  for entry in "${entry_files[@]}"; do
    if sudo grep -q "nvidia[-_]drm\.modeset=1" "$entry" 2>/dev/null; then
      info "$(basename "$entry"): nvidia-drm.modeset=1 already present"
      continue
    fi

    if ! sudo grep -q "^options" "$entry" 2>/dev/null; then
      warn "$(basename "$entry"): no 'options' line found, skipping"
      continue
    fi

    info "Backing up $(basename "$entry")..."
    sudo cp "$entry" "${entry}.backup.$(date +%Y%m%d%H%M%S)" || {
      err "Failed to backup $entry"
      continue
    }

    info "Adding nvidia-drm.modeset=1 to $(basename "$entry")..."
    if sudo sed -i '/^options/ s/$/ nvidia-drm.modeset=1/' "$entry"; then
      if sudo grep -q "nvidia-drm.modeset=1" "$entry"; then
        info "$(basename "$entry"): successfully updated"
        ((modified++))
      else
        err "$(basename "$entry"): failed to add parameter"
      fi
    else
      err "Failed to modify $entry"
    fi
  done

  if [[ $modified -gt 0 ]]; then
    info "Successfully updated $modified boot entry/entries"
    echo ""
    echo "  systemd-boot entries updated"
    echo "  Changes will take effect after reboot"
    echo ""
    NEEDS_REBOOT=1
  else
    warn "No entries were modified"
    show_manual_nvidia_instructions
  fi
}

show_manual_nvidia_instructions() {
  cat <<'MSG'
  Manual configuration required:
  Limine (CachyOS): Add nvidia-drm.modeset=1 inside the quotes of
                    KERNEL_CMDLINE[default]+="..." in /etc/default/limine,
                    then run: sudo limine-update
  Limine (vanilla): Add nvidia-drm.modeset=1 to the 'cmdline:' line in
                    /boot/limine.conf (root only)
  systemd-boot: Add to options in /boot/loader/entries/*.conf
  GRUB: Add to GRUB_CMDLINE_LINUX_DEFAULT, then run grub-mkconfig -o /boot/grub/grub.cfg
MSG
  warn "Gaming Mode may not work correctly without nvidia-drm.modeset=1"
}

install_nvidia_deckmode_env() {
  local lspci_output
  lspci_output=$(/usr/bin/lspci 2>/dev/null)
  if ! echo "$lspci_output" | grep -qi nvidia; then
    info "No NVIDIA detected; skipping NVIDIA Deck-mode env."
    return 0
  fi

  local env_file="/etc/environment.d/90-nvidia-gamescope.conf"

  if [ -f "$env_file" ]; then
    info "NVIDIA gamescope env already present: $env_file"
    return 0
  fi

  info "Installing NVIDIA gamescope env (Deck-mode style)..."
  sudo mkdir -p /etc/environment.d

  sudo tee "$env_file" >/dev/null <<'EOF'
GBM_BACKEND=nvidia-drm
__GLX_VENDOR_LIBRARY_NAME=nvidia
__VK_LAYER_NV_optimus=NVIDIA_only
EOF

  info "Installed $env_file"
  NEEDS_RELOGIN=1
}

check_steam_dependencies() {
  info "Checking Steam dependencies for Arch Linux..."

  info "Force refreshing package database from all mirrors..."
  sudo pacman -Syy || die "Failed to refresh package database"

  echo ""
  echo "================================================================"
  echo "  SYSTEM UPDATE RECOMMENDED"
  echo "================================================================"
  echo ""
  echo "  It's recommended to upgrade your system before installing"
  echo "  gaming dependencies to avoid package version conflicts."
  echo ""
  read -p "Upgrade system now? [Y/n]: " -n 1 -r
  echo
  if [[ ! $REPLY =~ ^[Nn]$ ]]; then
    info "Upgrading system..."
    sudo pacman -Syu || die "Failed to upgrade system"
  fi
  echo ""

  local -a missing_deps=()
  local -a optional_deps=()
  local multilib_enabled=false

  if ! command -v lspci >/dev/null 2>&1; then
    info "Installing pciutils for GPU detection..."
    sudo pacman -S --needed --noconfirm pciutils || die "Failed to install pciutils"
  fi

  if grep -q "^\[multilib\]" /etc/pacman.conf 2>/dev/null; then
    multilib_enabled=true
    info "Multilib repository: enabled"
  else
    err "Multilib repository: NOT enabled (required for Steam)"
    missing_deps+=("multilib-repository")
  fi

  local -a core_deps=(
    "steam"
    "lib32-vulkan-icd-loader"
    "vulkan-icd-loader"
    "lib32-mesa"
    "mesa"
    "mesa-utils"
    "lib32-glibc"
    "lib32-gcc-libs"
    "lib32-libx11"
    "lib32-libxss"
    "lib32-alsa-plugins"
    "lib32-libpulse"
    "lib32-openal"
    "lib32-nss"
    "lib32-libcups"
    "lib32-sdl2-compat"
    "lib32-freetype2"
    "lib32-fontconfig"
    "lib32-libnm"
    "networkmanager"
    "gamemode"
    "lib32-gamemode"
    "ttf-liberation"
    "xdg-user-dirs"
    "kbd"
  )

  local gpu_vendor
  gpu_vendor=$(/usr/bin/lspci 2>/dev/null | grep -iE 'vga|3d|display' || echo "")

  local has_nvidia=false has_amd=false

  if echo "$gpu_vendor" | grep -qi nvidia; then
    has_nvidia=true
    info "Detected NVIDIA GPU"
  fi
  if echo "$gpu_vendor" | grep -iqE 'amd|radeon|advanced micro'; then
    has_amd=true
    info "Detected AMD GPU"
  fi
  if echo "$gpu_vendor" | grep -iq intel; then
    info "Detected Intel GPU; no Intel-specific drivers will be installed"
  fi

  local primary_gpu="unknown"
  if $has_nvidia; then
    primary_gpu="nvidia"
  elif $has_amd; then
    primary_gpu="amd"
  fi

  PRIMARY_GPU="$primary_gpu"
  info "Primary GPU selection: $PRIMARY_GPU"

  local -a gpu_deps=()

  if $has_nvidia; then
    gpu_deps+=(
      "nvidia-utils"
      "lib32-nvidia-utils"
      "nvidia-settings"
      "libva-nvidia-driver"
    )
    # Check for any NVIDIA kernel module: packaged, DKMS, or CachyOS pre-built
    local has_nvidia_module=false
    if check_package "nvidia" || check_package "nvidia-dkms" || check_package "nvidia-open-dkms"; then
      has_nvidia_module=true
    else
      # CachyOS ships pre-built nvidia-open modules per kernel (e.g. linux-cachyos-nvidia-open)
      while IFS= read -r pkg; do
        if [[ "$pkg" =~ ^linux-.*nvidia ]]; then
          has_nvidia_module=true
          break
        fi
      done < <(pacman -Qq 2>/dev/null)
    fi
    if ! $has_nvidia_module; then
      info "Note: You may need to install 'nvidia', 'nvidia-dkms', or 'nvidia-open-dkms' kernel module"
      optional_deps+=("nvidia-dkms")
    fi
  fi

  if $has_amd; then
    gpu_deps+=(
      "vulkan-radeon"
      "lib32-vulkan-radeon"
      "libvdpau"
      "lib32-libvdpau"
    )
    ! check_package "xf86-video-amdgpu" && optional_deps+=("xf86-video-amdgpu")
  fi

  if ! $has_nvidia && ! $has_amd; then
    info "No NVIDIA/AMD GPU detected; installing AMD Vulkan drivers as fallback..."
    gpu_deps+=("vulkan-radeon" "lib32-vulkan-radeon")
  fi

  gpu_deps+=(
    "vulkan-tools"
    "vulkan-mesa-layers"
  )

  local -a recommended_deps=(
    "gamescope"
    "mangohud"
    "lib32-mangohud"
    "udisks2"
  )
  # NOTE: proton-ge-custom-bin removed from this list — installed directly
  # from GitHub releases by install_proton_ge_from_github() below.
  # The AUR pkg is just a thin wrapper that downloads the same tarball, and
  # AUR's git backend has been unreliable. GitHub releases path bypasses
  # AUR entirely (same approach protonup-qt/protonplus use).

  info "Checking core Steam dependencies..."
  for dep in "${core_deps[@]}"; do
    if ! check_package "$dep"; then
      missing_deps+=("$dep")
    fi
  done

  info "Checking GPU-specific dependencies..."
  for dep in "${gpu_deps[@]}"; do
    if ! check_package "$dep"; then
      missing_deps+=("$dep")
    fi
  done

  info "Checking recommended dependencies..."
  for dep in "${recommended_deps[@]}"; do
    if ! check_package "$dep"; then
      optional_deps+=("$dep")
    fi
  done

  echo ""
  echo "================================================================"
  echo "  STEAM DEPENDENCY CHECK RESULTS"
  echo "================================================================"
  echo ""

  if [ "$multilib_enabled" = false ]; then
    echo "  CRITICAL: Multilib repository must be enabled!"
    echo ""
    echo "  To enable multilib, edit /etc/pacman.conf and uncomment:"
    echo "    [multilib]"
    echo "    Include = /etc/pacman.d/mirrorlist"
    echo ""
    read -p "Enable multilib repository now? [y/N]: " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
      enable_multilib_repo
    else
      die "Multilib repository is required for Steam"
    fi
  fi

  local -a clean_missing=()
  for item in "${missing_deps[@]}"; do
    [[ -n "$item" && "$item" != "multilib-repository" ]] && clean_missing+=("$item")
  done
  missing_deps=("${clean_missing[@]+"${clean_missing[@]}"}")

  if ((${#missing_deps[@]})); then
    echo "  MISSING REQUIRED PACKAGES (${#missing_deps[@]}):"
    for dep in "${missing_deps[@]}"; do
      echo "    - $dep"
    done
    echo ""

    read -p "Install missing required packages? [Y/n]: " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Nn]$ ]]; then
      info "Installing missing dependencies..."
      sudo pacman -S --needed "${missing_deps[@]}" || die "Failed to install Steam dependencies"
      info "Required dependencies installed successfully"
    else
      die "Missing required Steam dependencies"
    fi
  else
    info "All required Steam dependencies are installed!"
  fi

  echo ""
  if ((${#optional_deps[@]})); then
    echo "  RECOMMENDED PACKAGES (${#optional_deps[@]}):"
    for dep in "${optional_deps[@]}"; do
      echo "    - $dep"
    done
    echo ""

    read -p "Install recommended packages? [y/N]: " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
      info "Syncing package database before installing..."
      sudo pacman -Sy || warn "Failed to sync package database"

      info "Installing recommended packages..."
      local -a failed_deps=()
      local -a pacman_deps=()
      for dep in "${optional_deps[@]}"; do
        if pacman -Si "$dep" &>/dev/null; then
          pacman_deps+=("$dep")
        else
          failed_deps+=("$dep")
        fi
      done
      if ((${#pacman_deps[@]})); then
        sudo pacman -S --needed --noconfirm "${pacman_deps[@]}" || warn "Some packages failed to install"
      fi

      if ((${#failed_deps[@]})); then
        local mirrorlist="/etc/pacman.d/mirrorlist"
        local fallback_mirror="Server = https://geo.mirror.pkgbuild.com/\$repo/os/\$arch"
        local added_fallback=false

        if ! grep -q "geo.mirror.pkgbuild.com" "$mirrorlist" 2>/dev/null; then
          info "Some packages not found in current repos. Adding official Arch mirror..."
          sudo sed -i "1i $fallback_mirror" "$mirrorlist"
          sudo pacman -Syy || warn "Failed to sync with official mirror"
          added_fallback=true
        fi

        local -a aur_optional=()
        local -a retry_pacman=()
        for dep in "${failed_deps[@]}"; do
          if pacman -Si "$dep" &>/dev/null; then
            retry_pacman+=("$dep")
          else
            aur_optional+=("$dep")
          fi
        done
        if ((${#retry_pacman[@]})); then
          info "Found packages in official repos: ${retry_pacman[*]}"
          sudo pacman -S --needed --noconfirm "${retry_pacman[@]}" || warn "Some packages failed to install from official repos"
        fi

        if $added_fallback; then
          sudo sed -i '/geo\.mirror\.pkgbuild\.com/d' "$mirrorlist"
          sudo pacman -Syy 2>/dev/null || true
          info "Removed fallback mirror, restored original mirrorlist"
        fi
      else
        local -a aur_optional=()
      fi

      if ((${#aur_optional[@]})); then
        echo ""
        info "The following packages are from AUR and need an AUR helper:"
        for dep in "${aur_optional[@]}"; do
          echo "    - $dep"
        done
        echo ""

        local aur_helper_available=""
        if command -v yay >/dev/null 2>&1; then
          if check_aur_helper_functional yay; then
            aur_helper_available="yay"
          else
            warn "yay is installed but broken (needs rebuild after system update)"
            read -p "Rebuild yay now? [Y/n]: " -n 1 -r
            echo
            REPLY=${REPLY:-Y}
            if [[ $REPLY =~ ^[Yy]$ ]] && rebuild_yay && check_aur_helper_functional yay; then
              aur_helper_available="yay"
            fi
          fi
        elif command -v paru >/dev/null 2>&1; then
          if check_aur_helper_functional paru; then
            aur_helper_available="paru"
          fi
        fi

        if [[ -n "$aur_helper_available" ]]; then
          read -p "Install AUR packages with $aur_helper_available? [y/N]: " -n 1 -r
          echo
          if [[ $REPLY =~ ^[Yy]$ ]]; then
            # Pre-flight: confirm AUR is reachable. paru/yay don't retry
            # transient `git clone` failures, and this block's per-pkg
            # `|| warn` means a network blip silently skips the install —
            # e.g. proton-ge-custom-bin missing despite "successful" run.
            local aur_reachable=false
            for probe in 1 2 3; do
              if curl -sSf --max-time 10 -o /dev/null "https://aur.archlinux.org/" 2>/dev/null; then
                aur_reachable=true
                break
              fi
              warn "AUR not reachable (attempt $probe/3) — waiting 10s..."
              sleep 10
            done
            if ! $aur_reachable; then
              err "Cannot reach https://aur.archlinux.org/ — skipping AUR recommended packages."
              err "Install manually later: $aur_helper_available -S ${aur_optional[*]}"
            else
              for dep in "${aur_optional[@]}"; do
                info "Installing $dep..."
                # Use --skipreview (paru) to avoid blocking on out-of-date prompts with --noconfirm
                local aur_flags=(--needed --noconfirm)
                if [[ "$aur_helper_available" == "paru" ]]; then
                  aur_flags+=(--skipreview)
                fi
                local dep_ok=false
                for attempt in 1 2 3; do
                  if $aur_helper_available -S "${aur_flags[@]}" "$dep"; then
                    dep_ok=true
                    break
                  fi
                  if [[ $attempt -lt 3 ]]; then
                    warn "Install of $dep failed (attempt $attempt/3) — retrying in 15s..."
                    sleep 15
                  fi
                done
                $dep_ok || warn "Failed to install $dep from AUR after 3 attempts"
              done
            fi
          fi
        else
          info "No functional AUR helper found (yay/paru). Install manually if desired."
        fi
      fi
    fi
  else
    info "All recommended packages are already installed!"
  fi

  echo ""
  echo "================================================================"

  install_proton_ge_from_github

  check_steam_config
}

# Install latest GE-Proton release tarball straight from GloriousEggroll's
# GitHub releases into the per-user compatibilitytools.d/. This is the same
# thing the AUR pkg `proton-ge-custom-bin` does (and what protonup-qt does
# under the hood), but without depending on AUR's git backend — which has
# been flaky enough to silently skip Proton-GE on past installs.
install_proton_ge_from_github() {
  local target_user="${SUDO_USER:-$USER}"
  local user_home
  user_home=$(getent passwd "$target_user" | cut -d: -f6)
  if [[ -z "$user_home" || ! -d "$user_home" ]]; then
    warn "Could not resolve home dir for $target_user — skipping Proton-GE install"
    return 0
  fi

  local install_dir="$user_home/.steam/steam/compatibilitytools.d"

  # Idempotent: if any GE-Proton* directory already exists (from AUR pkg,
  # protonup-qt, or a previous run of this function), don't reinstall.
  if compgen -G "$install_dir/GE-Proton*" > /dev/null 2>&1; then
    local existing
    existing=$(basename "$(compgen -G "$install_dir/GE-Proton*" | head -1)")
    info "Proton-GE already installed: $existing — skipping"
    return 0
  fi

  echo ""
  echo "================================================================"
  echo "  PROTON-GE INSTALL (direct from GitHub releases)"
  echo "================================================================"
  echo ""
  echo "  Downloads the latest GE-Proton release (~700 MB) directly from"
  echo "  github.com/GloriousEggroll/proton-ge-custom into:"
  echo "    $install_dir"
  echo ""
  read -p "Install Proton-GE now? [Y/n]: " -n 1 -r
  echo
  if [[ $REPLY =~ ^[Nn]$ ]]; then
    info "Skipping Proton-GE install"
    return 0
  fi

  # Need curl and tar — both ship in base CachyOS, but guard anyway.
  for cmd in curl tar sha512sum; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      err "Required command '$cmd' missing — cannot install Proton-GE from GitHub"
      return 1
    fi
  done

  info "Fetching latest GE-Proton release info from GitHub API..."
  local api_url="https://api.github.com/repos/GloriousEggroll/proton-ge-custom/releases/latest"
  local release_json
  release_json=$(curl -sSfL --max-time 20 --retry 3 --retry-delay 5 "$api_url") || {
    err "Failed to fetch release info from $api_url"
    return 1
  }

  local tarball_url sha_url
  tarball_url=$(echo "$release_json" | grep -oE '"browser_download_url"[[:space:]]*:[[:space:]]*"[^"]+\.tar\.gz"' | head -1 | sed -E 's/.*"([^"]+)"$/\1/')
  sha_url=$(echo "$release_json" | grep -oE '"browser_download_url"[[:space:]]*:[[:space:]]*"[^"]+\.sha512sum"' | head -1 | sed -E 's/.*"([^"]+)"$/\1/')

  if [[ -z "$tarball_url" ]]; then
    err "Could not find .tar.gz asset URL in GitHub release JSON"
    return 1
  fi

  local tarball_name sha_name
  tarball_name=$(basename "$tarball_url")
  sha_name=$(basename "$sha_url")
  info "Latest release: ${tarball_name%.tar.gz}"

  # Ensure target dir exists and is owned by the user
  if [[ ! -d "$install_dir" ]]; then
    sudo -u "$target_user" mkdir -p "$install_dir" || {
      err "Failed to create $install_dir"
      return 1
    }
  fi

  local tmpdir
  tmpdir=$(mktemp -d) || { err "mktemp failed"; return 1; }
  # NOTE: do NOT use a RETURN trap here. The script has `set -u` and the
  # RETURN trap fires on caller-function returns too (functrace semantics),
  # at which point the local `tmpdir` is out of scope → "unbound variable"
  # at the trap's `"$tmpdir"` expansion. Explicit cleanup at each exit
  # path is safer.
  _proton_ge_cleanup() { rm -rf "$tmpdir"; }

  info "Downloading $tarball_name (this can take a few minutes)..."
  if ! curl -fL --retry 3 --retry-delay 10 -C - --max-time 1800 \
        -o "$tmpdir/$tarball_name" "$tarball_url"; then
    err "Download failed: $tarball_url"
    _proton_ge_cleanup
    return 1
  fi

  if [[ -n "$sha_url" ]]; then
    info "Downloading checksum..."
    if curl -fsSL --retry 3 --max-time 30 -o "$tmpdir/$sha_name" "$sha_url"; then
      info "Verifying SHA512..."
      ( cd "$tmpdir" && sha512sum -c "$sha_name" --status ) || {
        err "SHA512 verification failed — refusing to install"
        _proton_ge_cleanup
        return 1
      }
      info "Checksum OK"
    else
      warn "Could not download checksum file — proceeding without verification"
    fi
  fi

  info "Extracting into $install_dir..."
  if ! sudo -u "$target_user" tar -xzf "$tmpdir/$tarball_name" -C "$install_dir"; then
    err "Extraction failed"
    _proton_ge_cleanup
    return 1
  fi

  _proton_ge_cleanup

  local extracted="${tarball_name%.tar.gz}"
  if [[ ! -d "$install_dir/$extracted" ]]; then
    warn "Expected $install_dir/$extracted not found after extract — check manually"
  else
    info "Proton-GE installed: $install_dir/$extracted"
  fi
  info "Restart Steam fully (tray icon → Exit, then relaunch) to pick it up."
  return 0
}

enable_multilib_repo() {
  info "Enabling multilib repository..."

  sudo cp /etc/pacman.conf "/etc/pacman.conf.backup.$(date +%Y%m%d%H%M%S)" || die "Failed to backup pacman.conf"
  sudo sed -i '/^#\[multilib\]/,/^#Include/ s/^#//' /etc/pacman.conf || die "Failed to enable multilib"

  if grep -q "^\[multilib\]" /etc/pacman.conf 2>/dev/null; then
    info "Multilib repository enabled successfully"
    echo ""
    info "Updating system to enable multilib packages..."
    read -p "Proceed with system upgrade? [Y/n]: " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Nn]$ ]]; then
      sudo pacman -Syu || die "Failed to update and upgrade system"
    else
      die "System upgrade required after enabling multilib"
    fi
  else
    die "Failed to enable multilib repository"
  fi
}

check_steam_config() {
  info "Checking Steam configuration..."

  local missing_groups=()

  if ! groups | grep -qw 'video'; then
    missing_groups+=("video")
  fi

  if ! groups | grep -qw 'input'; then
    missing_groups+=("input")
  fi

  if ! groups | grep -qw 'wheel'; then
    missing_groups+=("wheel")
  fi

  if ((${#missing_groups[@]})); then
    echo ""
    echo "================================================================"
    echo "  USER GROUP PERMISSIONS"
    echo "================================================================"
    echo ""
    echo "  Your user needs to be added to the following groups:"
    echo ""
    for group in "${missing_groups[@]}"; do
      case "$group" in
        video) echo "    - video  - Required for GPU hardware access" ;;
        input) echo "    - input  - Required for controller/gamepad support and gaming mode keybinds" ;;
        wheel) echo "    - wheel  - Required for NetworkManager control in gaming mode" ;;
      esac
    done
    echo ""
    echo "  NOTE: After adding groups, you MUST log out and log back in"
    echo ""
    read -p "Add user to ${missing_groups[*]} group(s)? [Y/n]: " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Nn]$ ]]; then
      local groups_to_add
      groups_to_add=$(IFS=,; echo "${missing_groups[*]}")
      info "Adding user to groups: $groups_to_add"
      if sudo usermod -aG "$groups_to_add" "$USER"; then
        info "Successfully added user to group(s): $groups_to_add"
        NEEDS_RELOGIN=1
      else
        err "Failed to add user to groups"
      fi
    fi
  else
    info "User is in video, input, and wheel groups - permissions OK"
  fi

  if [ -d "$HOME/.steam" ]; then
    info "Steam directory found at ~/.steam"
  fi

  if [ -d "$HOME/.local/share/Steam" ]; then
    info "Steam data directory found at ~/.local/share/Steam"
  fi

  if [ -f /proc/sys/vm/swappiness ]; then
    local swappiness
    swappiness=$(cat /proc/sys/vm/swappiness)
    if [ "$swappiness" -gt 10 ]; then
      info "Tip: Consider lowering vm.swappiness to 10 for better gaming performance"
    fi
  fi

  local max_files
  max_files=$(ulimit -n 2>/dev/null || echo "0")
  if [ "$max_files" -lt 524288 ]; then
    info "Tip: Increase open file limit for esync support"
  fi
}

setup_performance_permissions() {
  local udev_rules_file="/etc/udev/rules.d/99-gaming-performance.rules"
  local sudoers_file="/etc/sudoers.d/gaming-mode-sysctl"
  local needs_setup=false

  if [ ! -f "$udev_rules_file" ] || [ ! -f "$sudoers_file" ]; then
    needs_setup=true
  fi

  if [ "$needs_setup" = false ]; then
    info "Performance permissions already configured"
    return 0
  fi

  echo ""
  echo "================================================================"
  echo "  PERFORMANCE PERMISSIONS SETUP"
  echo "================================================================"
  echo ""
  echo "  To avoid sudo password prompts during gaming, we need to set"
  echo "  up permissions for CPU and GPU performance control."
  echo ""
  read -p "Set up passwordless performance controls? [Y/n]: " -n 1 -r
  echo

  if [[ $REPLY =~ ^[Nn]$ ]]; then
    info "Skipping permissions setup"
    return 0
  fi

  if [ ! -f "$udev_rules_file" ]; then
    info "Creating udev rules for CPU/GPU performance control..."

    if sudo tee "$udev_rules_file" > /dev/null <<'UDEV_RULES'
KERNEL=="cpu[0-9]*", SUBSYSTEM=="cpu", ACTION=="add", RUN+="/bin/chmod 666 /sys/devices/system/cpu/%k/cpufreq/scaling_governor"
KERNEL=="card[0-9]", SUBSYSTEM=="drm", DRIVERS=="amdgpu", ACTION=="add", RUN+="/bin/chmod 666 /sys/class/drm/%k/device/power_dpm_force_performance_level"
KERNEL=="card[0-9]", SUBSYSTEM=="drm", DRIVERS=="i915", ACTION=="add", RUN+="/bin/chmod 666 /sys/class/drm/%k/gt_boost_freq_mhz"
KERNEL=="card[0-9]", SUBSYSTEM=="drm", DRIVERS=="i915", ACTION=="add", RUN+="/bin/chmod 666 /sys/class/drm/%k/gt_min_freq_mhz"
KERNEL=="card[0-9]", SUBSYSTEM=="drm", DRIVERS=="i915", ACTION=="add", RUN+="/bin/chmod 666 /sys/class/drm/%k/gt_max_freq_mhz"
UDEV_RULES
    then
      info "Udev rules created successfully"
      sudo udevadm control --reload-rules || true
      sudo udevadm trigger --subsystem-match=cpu --subsystem-match=drm || true
    fi
  fi

  if [[ -f "$sudoers_file" ]]; then
    info "Performance sudoers already exist at $sudoers_file"
  else
    info "Creating sudoers rule for Performance Mode sysctl tuning..."
    sudo mkdir -p /etc/sudoers.d

    if sudo tee "$sudoers_file" > /dev/null << 'SUDOERS_PERF'
%video ALL=(ALL) NOPASSWD: /usr/bin/sysctl -w kernel.sched_autogroup_enabled=*
# kernel.sched_migration_cost_ns / sched_min_granularity_ns / sched_latency_ns
# were CFS-specific knobs removed when EEVDF replaced CFS in Linux 6.6.
# Removed here to avoid granting permissions to call non-existent sysctls.
%video ALL=(ALL) NOPASSWD: /usr/bin/sysctl -w vm.swappiness=*
%video ALL=(ALL) NOPASSWD: /usr/bin/sysctl -w vm.dirty_ratio=*
%video ALL=(ALL) NOPASSWD: /usr/bin/sysctl -w vm.dirty_background_ratio=*
%video ALL=(ALL) NOPASSWD: /usr/bin/sysctl -w vm.dirty_writeback_centisecs=*
%video ALL=(ALL) NOPASSWD: /usr/bin/sysctl -w vm.dirty_expire_centisecs=*
%video ALL=(ALL) NOPASSWD: /usr/bin/sysctl -w fs.inotify.max_user_watches=*
%video ALL=(ALL) NOPASSWD: /usr/bin/sysctl -w fs.inotify.max_user_instances=*
%video ALL=(ALL) NOPASSWD: /usr/bin/sysctl -w fs.file-max=*
%video ALL=(ALL) NOPASSWD: /usr/bin/sysctl -w net.core.rmem_max=*
%video ALL=(ALL) NOPASSWD: /usr/bin/sysctl -w net.core.wmem_max=*
%video ALL=(ALL) NOPASSWD: /usr/bin/nvidia-smi -pm *
%video ALL=(ALL) NOPASSWD: /usr/bin/nvidia-smi -pl *
SUDOERS_PERF
    then
      sudo chmod 0440 "$sudoers_file"
      info "Performance sudoers created successfully"
    else
      err "Failed to create performance sudoers file"
    fi
  fi

  local memlock_file="/etc/security/limits.d/99-gaming-memlock.conf"
  if [ ! -f "$memlock_file" ]; then
    info "Creating memlock limits for gaming performance..."
    if sudo tee "$memlock_file" > /dev/null << 'MEMLOCKCONF'
* soft memlock 2147484
* hard memlock 2147484
MEMLOCKCONF
    then
      info "Memlock limits configured (2GB)"
    fi
  fi

  local pipewire_conf_dir="/etc/pipewire/pipewire.conf.d"
  local pipewire_conf="$pipewire_conf_dir/10-gaming-latency.conf"
  if [ ! -f "$pipewire_conf" ]; then
    info "Creating PipeWire low-latency audio configuration..."
    sudo mkdir -p "$pipewire_conf_dir"
    if sudo tee "$pipewire_conf" > /dev/null << 'PIPEWIRECONF'
context.properties = {
    default.clock.min-quantum = 256
}
PIPEWIRECONF
    then
      info "PipeWire gaming latency configured"
    fi
  fi

  info "Performance permissions configured"
  return 0
}

setup_shader_cache() {
  local env_file="/etc/environment.d/99-shader-cache.conf"

  if [ -f "$env_file" ]; then
    info "Shader cache configuration already exists"
    return 0
  fi

  echo ""
  echo "================================================================"
  echo "  SHADER CACHE OPTIMIZATION"
  echo "================================================================"
  echo ""
  echo "  Configuring shader cache sizes for better gaming performance."
  echo "  This reduces stuttering in games by caching compiled shaders."
  echo ""
  read -p "Configure shader cache optimization? [Y/n]: " -n 1 -r
  echo

  if [[ $REPLY =~ ^[Nn]$ ]]; then
    info "Skipping shader cache configuration"
    return 0
  fi

  info "Creating shader cache configuration..."
  sudo mkdir -p /etc/environment.d || { warn "Failed to create /etc/environment.d"; return 0; }
  local tmp_shader
  tmp_shader=$(mktemp) || { warn "Failed to create temp file"; return 0; }

  cat > "$tmp_shader" << 'SHADERCACHE'
MESA_SHADER_CACHE_MAX_SIZE=12G
MESA_SHADER_CACHE_DISABLE_CLEANUP=1
RADV_PERFTEST=gpl
__GL_SHADER_DISK_CACHE=1
__GL_SHADER_DISK_CACHE_SIZE=12884901888
__GL_SHADER_DISK_CACHE_SKIP_CLEANUP=1
DXVK_STATE_CACHE=1
FCITX_NO_WAYLAND_DIAGNOSE=1
SHADERCACHE

  if sudo cp "$tmp_shader" "$env_file"; then
    rm -f "$tmp_shader"
    sudo chmod 644 "$env_file"
    info "Shader cache configured for all GPUs (AMD/NVIDIA + Proton)"
  else
    rm -f "$tmp_shader"
    warn "Failed to create shader cache configuration"
  fi
}

setup_fcitx_silence() {
  local env_dir="$HOME/.config/environment.d"
  local env_file="$env_dir/90-fcitx-wayland.conf"

  if [[ ! -f "$env_file" ]] || ! grep -q "FCITX_NO_WAYLAND_DIAGNOSE=1" "$env_file" 2>/dev/null; then
    mkdir -p "$env_dir" || return 0
    cat > "$env_file" <<'EOF'
FCITX_NO_WAYLAND_DIAGNOSE=1
EOF
    info "Created fcitx Wayland silence config"
    NEEDS_RELOGIN=1
  fi
}

setup_requirements() {
  local -a required_packages=("steam" "gamescope" "mangohud" "python" "python-evdev" "libcap" "gamemode" "curl" "pciutils" "ntfs-3g" "xcb-util-cursor")
  local -a packages_to_install=()
  for pkg in "${required_packages[@]}"; do
    check_package "$pkg" || packages_to_install+=("$pkg")
  done

  if ((${#packages_to_install[@]})); then
    info "The following packages are required: ${packages_to_install[*]}"
    read -p "Install missing packages? [Y/n]: " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Nn]$ ]]; then
      sudo pacman -S --needed "${packages_to_install[@]}" || die "package install failed"
    else
      die "Required packages missing - cannot continue"
    fi
  else
    info "All required packages present."
  fi

  setup_performance_permissions
  setup_fcitx_silence
  setup_shader_cache

  if [[ "${PERFORMANCE_MODE,,}" == "enabled" ]] && command -v gamescope >/dev/null 2>&1; then
    if ! getcap "$(command -v gamescope)" 2>/dev/null | grep -q 'cap_sys_nice'; then
      echo ""
      echo "================================================================"
      echo "  GAMESCOPE CAPABILITY REQUEST"
      echo "================================================================"
      echo ""
      echo "  Performance mode requires granting cap_sys_nice to gamescope."
      echo ""
      read -p "Grant cap_sys_nice to gamescope? [Y/n]: " -n 1 -r
      echo
      if [[ ! $REPLY =~ ^[Nn]$ ]]; then
        sudo setcap 'cap_sys_nice=eip' "$(command -v gamescope)" || warn "Failed to set capability"
        info "Capability granted to gamescope"
      fi
    fi
  fi
}

# Detect the KDE Plasma session name from available .desktop files
detect_kde_session_name() {
  local session_name="plasma"
  # Check wayland sessions first (preferred)
  if [[ -f /usr/share/wayland-sessions/plasma.desktop ]]; then
    session_name="plasma"
  elif [[ -f /usr/share/wayland-sessions/plasmawayland.desktop ]]; then
    session_name="plasmawayland"
  # Fallback to X11
  elif [[ -f /usr/share/xsessions/plasma.desktop ]]; then
    session_name="plasma"
  elif [[ -f /usr/share/xsessions/plasmax11.desktop ]]; then
    session_name="plasmax11"
  fi
  echo "$session_name"
}

# Detect the active display/login manager. CachyOS switched the default from
# SDDM to KDE's plasma-login-manager (binary: plasmalogin, service:
# plasmalogin.service, config dir: /etc/plasmalogin.conf.d). The two share the
# same INI grammar, so we just parameterize service name + config paths and
# reuse the same logic for either.
# Sets globals: DM_NAME, DM_SERVICE, DM_CONF, DM_CONF_DIR
detect_display_manager() {
  local dm_target=""
  if [[ -L /etc/systemd/system/display-manager.service ]]; then
    dm_target=$(basename "$(readlink /etc/systemd/system/display-manager.service)" .service)
  fi
  case "$dm_target" in
    plasmalogin)
      DM_NAME="plasma-login-manager"
      DM_SERVICE="plasmalogin"
      DM_CONF="/etc/plasmalogin.conf"
      DM_CONF_DIR="/etc/plasmalogin.conf.d"
      ;;
    sddm)
      DM_NAME="sddm"
      DM_SERVICE="sddm"
      DM_CONF="/etc/sddm.conf"
      DM_CONF_DIR="/etc/sddm.conf.d"
      ;;
    *)
      if systemctl list-unit-files plasmalogin.service &>/dev/null || command -v plasmalogin >/dev/null 2>&1; then
        DM_NAME="plasma-login-manager"
        DM_SERVICE="plasmalogin"
        DM_CONF="/etc/plasmalogin.conf"
        DM_CONF_DIR="/etc/plasmalogin.conf.d"
      elif systemctl list-unit-files sddm.service &>/dev/null || command -v sddm >/dev/null 2>&1; then
        DM_NAME="sddm"
        DM_SERVICE="sddm"
        DM_CONF="/etc/sddm.conf"
        DM_CONF_DIR="/etc/sddm.conf.d"
      else
        die "No supported display manager found (need plasma-login-manager or sddm)"
      fi
      ;;
  esac
}

setup_kde_shortcut() {
  local user_home="$1"

  info "Setting up KDE Plasma global shortcut for Gaming Mode..."

  # Create a .desktop file for the switch-to-gaming action
  local desktop_dir="/usr/share/applications"
  local desktop_file="$desktop_dir/switch-to-gaming.desktop"

  sudo tee "$desktop_file" > /dev/null << 'DESKTOP_ENTRY'
[Desktop Entry]
Type=Application
Name=Switch to Gaming Mode
Comment=Switch from KDE Plasma to Gaming Mode (Gamescope)
Exec=/usr/local/bin/switch-to-gaming
Icon=input-gaming
NoDisplay=true
Terminal=false
Categories=Game;
DESKTOP_ENTRY

  sudo chmod 644 "$desktop_file"
  info "Created $desktop_file"

  # Register the global shortcut in KDE's kglobalshortcutsrc
  local shortcuts_file="${user_home}/.config/kglobalshortcutsrc"

  if [[ -f "$shortcuts_file" ]]; then
    if grep -q "\[switch-to-gaming.desktop\]" "$shortcuts_file" 2>/dev/null; then
      info "Gaming Mode shortcut already exists in kglobalshortcutsrc"
      return 0
    fi

    # Clear the Screen Reader shortcut (Meta+Alt+S) to avoid conflict
    if grep -q "Toggle Screen Reader On and Off=Meta+Alt+S" "$shortcuts_file" 2>/dev/null; then
      info "Clearing conflicting Screen Reader shortcut (Meta+Alt+S)..."
      sed -i 's|Toggle Screen Reader On and Off=Meta+Alt+S,Meta+Alt+S,|Toggle Screen Reader On and Off=none,none,|' "$shortcuts_file"
      info "Screen Reader shortcut cleared"
    fi
  fi

  # Append the shortcut configuration
  cat >> "$shortcuts_file" << 'KDE_SHORTCUT'

[switch-to-gaming.desktop]
_k_friendly_name=Switch to Gaming Mode
_launch=Meta+Alt+S,none,Switch to Gaming Mode
KDE_SHORTCUT

  info "Added Super+Alt+S shortcut to KDE global shortcuts"

  # Also create a khotkeys entry as fallback for older Plasma versions
  local khotkeys_file="${user_home}/.config/khotkeysrc"

  if [[ -f "$khotkeys_file" ]]; then
    if grep -q "switch-to-gaming" "$khotkeys_file" 2>/dev/null; then
      info "Gaming Mode khotkey already exists"
      return 0
    fi
  fi

  # Notify KDE to reload shortcuts if running
  if command -v dbus-send >/dev/null 2>&1; then
    dbus-send --type=signal --dest=org.kde.kglobalaccel /kglobalaccel org.kde.KGlobalAccel.yourShortcutsChanged 2>/dev/null || true
  fi

  # Also try qdbus approach for Plasma 6
  if command -v qdbus6 >/dev/null 2>&1; then
    qdbus6 org.kde.kglobalaccel /kglobalaccel org.kde.KGlobalAccel.blockGlobalShortcuts false 2>/dev/null || true
  fi

  info "KDE shortcut configuration complete"
  echo "  NOTE: You may need to log out and back in for the shortcut to activate."
  echo "  You can also manually set it in System Settings > Shortcuts > Custom Shortcuts."
}

setup_session_switching() {
  echo ""
  echo "================================================================"
  echo "  SESSION SWITCHING SETUP (KDE Plasma <-> Gamescope)"
  echo "  Using ChimeraOS gamescope-session packages"
  echo "================================================================"
  echo ""

  detect_display_manager
  info "Display manager: ${DM_NAME} (service ${DM_SERVICE}, conf ${DM_CONF_DIR})"

  # Intel-only check
  if check_intel_only; then
    echo ""
    echo "  NO DICE - INTEL ONLY DETECTED"
    echo ""
    err "This setup does not support Intel GPUs (iGPU or Arc)."
    echo ""
    echo "  Gaming Mode requires AMD or NVIDIA graphics."
    echo ""
    exit 1
  fi

  echo "  This will:"
  echo "    - Install gamescope-session-git and gamescope-session-steam-git from AUR"
  echo "    - Configure Super+Alt+S to switch to Gaming Mode"
  echo "    - Configure Steam's 'Exit to Desktop' to return to KDE Plasma"
  echo ""
  read -p "Set up session switching? [Y/n]: " -n 1 -r
  echo
  if [[ $REPLY =~ ^[Nn]$ ]]; then
    info "Skipping session switching setup"
    return 0
  fi

  local current_user="${SUDO_USER:-$USER}"
  local user_home
  user_home=$(getent passwd "$current_user" | cut -d: -f6)

  local monitor_width=1920
  local monitor_height=1080
  local monitor_refresh=60
  local monitor_output=""

  local -a dgpu_monitors=()
  local dgpu_card=""
  local dgpu_type=""
  detect_dgpu_monitors dgpu_monitors dgpu_card dgpu_type

  if [[ -z "$dgpu_card" ]]; then
    if [[ "$dgpu_type" == "NVIDIA" ]]; then
      warn "NVIDIA GPU detected but no DRM card found!"
      echo ""
      echo "  This usually means nvidia-drm.modeset=1 is not set."
      echo "  Continuing setup with defaults (2560x1440@60 on NVIDIA)."
      echo "  A REBOOT will be required for full functionality."
      echo ""
      NEEDS_REBOOT=1
      # Use safe NVIDIA defaults so session switching config is still created
      dgpu_card="card0"
      monitor_width=2560
      monitor_height=1440
      monitor_refresh=60
    fi

    if [[ "$dgpu_type" != "NVIDIA" ]]; then
    # No dGPU and not NVIDIA - check for APU
    local apu_card=""
    local apu_monitors=()
    local card_name driver_link driver conn_dir conn_name status resolution mode_file

    for card_path in /sys/class/drm/card[0-9]*; do
      card_name=$(basename "$card_path")
      [[ "$card_name" == render* ]] && continue
      driver_link="$card_path/device/driver"
      [[ -L "$driver_link" ]] || continue
      driver=$(basename "$(readlink "$driver_link")")

      if [[ "$driver" == "amdgpu" ]] && is_amd_igpu_card "$card_path"; then
        apu_card="$card_name"
        for connector in "$card_path"/"$card_name"-*/status; do
          [[ -f "$connector" ]] || continue
          conn_dir=$(dirname "$connector")
          conn_name=$(basename "$conn_dir")
          conn_name=${conn_name#card*-}
          [[ "$conn_name" == Writeback* ]] && continue
          status=$(cat "$connector" 2>/dev/null)
          if [[ "$status" == "connected" ]]; then
            resolution=""
            mode_file="$conn_dir/modes"
            [[ -f "$mode_file" ]] && [[ -s "$mode_file" ]] && resolution=$(head -1 "$mode_file" 2>/dev/null)
            apu_monitors+=("$conn_name|$resolution")
          fi
        done
        break
      fi
    done

    if [[ -n "$apu_card" && ${#apu_monitors[@]} -gt 0 ]]; then
      echo ""
      info "No discrete GPU found, but detected AMD APU ($apu_card)"
      echo ""
      echo "  This system has an AMD APU which can run Gaming Mode."
      echo "  Detected monitors: ${#apu_monitors[@]}"
      echo ""
      read -p "  Set up Gaming Mode for APU? [Y/n]: " -n 1 -r
      echo
      if [[ ! $REPLY =~ ^[Nn]$ ]]; then
        dgpu_card="$apu_card"
        dgpu_type="AMD APU"
        dgpu_monitors=("${apu_monitors[@]}")
        info "Configuring Gaming Mode for AMD APU"
      else
        info "Skipping APU Gaming Mode setup"
        return 0
      fi
    else
      err "No discrete GPU (dGPU) or AMD APU found!"
      echo "  Gaming mode requires a supported GPU with a connected display."
      return 1
    fi
    fi
  fi

  info "Found $dgpu_type on $dgpu_card"

  if [[ ${#dgpu_monitors[@]} -eq 0 ]]; then
    if [[ "$dgpu_type" == "NVIDIA" && "$NEEDS_REBOOT" -eq 1 ]]; then
      info "No monitors detected on NVIDIA (nvidia-drm.modeset=1 not yet active)"
      info "Using defaults: 2560x1440@60 — will auto-detect after reboot"
    else
      err "No monitors connected to dGPU!"
      echo ""
      echo "  Gaming mode requires a monitor connected to the discrete GPU."
      echo "  Please connect an external monitor to your dGPU port (HDMI/DP/USB-C)"
      echo "  and re-run this installer."
      echo ""
      return 1
    fi
  fi

  if [[ ${#dgpu_monitors[@]} -eq 1 ]]; then
    local entry="${dgpu_monitors[0]}"
    monitor_output="${entry%%|*}"
    local res="${entry##*|}"
    if [[ -n "$res" ]]; then
      monitor_width="${res%%x*}"
      monitor_height="${res##*x}"
      monitor_height="${monitor_height%%@*}"
      [[ "$res" == *@* ]] && monitor_refresh="${res##*@}" && monitor_refresh="${monitor_refresh%%.*}"
    fi
  else
    echo ""
    echo "  Multiple monitors connected to $dgpu_type:"
    local i=1
    for entry in "${dgpu_monitors[@]}"; do
      local name="${entry%%|*}"
      local res="${entry##*|}"
      echo "    $i) $name ${res:+($res)}"
      ((i++))
    done
    echo ""
    read -r -p "Select monitor for Gaming Mode [1-${#dgpu_monitors[@]}]: " selection
    if [[ ! "$selection" =~ ^[0-9]+$ ]] || ((selection < 1 || selection > ${#dgpu_monitors[@]})); then
      selection=1
    fi
    local entry="${dgpu_monitors[$((selection-1))]}"
    monitor_output="${entry%%|*}"
    local res="${entry##*|}"
    if [[ -n "$res" ]]; then
      monitor_width="${res%%x*}"
      monitor_height="${res##*x}"
      monitor_height="${monitor_height%%@*}"
      [[ "$res" == *@* ]] && monitor_refresh="${res##*@}" && monitor_refresh="${monitor_refresh%%.*}"
    fi
  fi

  info "Selected dGPU display: ${monitor_output} (${monitor_width}x${monitor_height}@${monitor_refresh}Hz)"

  info "Checking for old custom session files to clean up..."

  local -a old_files=(
    "/usr/bin/gamescope-session"
    "/usr/share/wayland-sessions/gamescope-session.desktop"
    "/usr/bin/jupiter-biosupdate"
    "/usr/bin/steamos-update"
    "/usr/bin/steamos-select-branch"
    "/usr/bin/steamos-session-select"
  )

  local cleaned=false
  local skipped=false
  for old_file in "${old_files[@]}"; do
    [[ -f "$old_file" ]] || continue
    # Don't delete files owned by an installed package — the steamos-* helpers
    # are now shipped by gamescope-session-steam-git (the AUR package this
    # script later installs). Blind deletion forces an unnecessary AUR rebuild
    # on every run and briefly leaves the system with missing binaries.
    if pacman -Qo "$old_file" &>/dev/null; then
      skipped=true
      continue
    fi
    info "Removing old file: $old_file"
    sudo rm -f "$old_file" && cleaned=true
  done

  if $cleaned; then
    info "Old custom session files removed"
  elif $skipped; then
    info "No orphan files to clean up (package-owned files left intact)"
  else
    info "No old files to clean up"
  fi

  info "Checking for ChimeraOS gamescope-session packages..."

  local -a aur_packages=()
  local -a packages_to_remove=()

  # Use literal-package detection, NOT provides-aware detection.
  # `check_package` (pacman -Qi) returns true for "gamescope-session-steam-git"
  # whenever gamescope-session-cachyos is installed (it declares
  # Provides=gamescope-session-steam-git), which previously caused this block
  # to (a) think the AUR package was already in place and (b) queue the wrong
  # name for removal — leading to `pacman -Rdd gamescope-session-steam-git`
  # failing with "target not found" while the real conflicting package
  # (cachyos) stayed installed and blocked the AUR build.
  literal_installed() { pacman -Qq 2>/dev/null | grep -qx "$1"; }

  # If the CachyOS provider is installed, treat both -git names as not-installed
  # and queue the provider for removal up front. -git packages ship files
  # (notably /usr/share/gamescope-session-plus/gamescope-session-plus) that the
  # autologin wrapper depends on; the cachyos provider does not.
  #
  # Also queue jupiter-hw-support: it's pulled in as a hard dep of
  # gamescope-session-cachyos and owns /usr/bin/jupiter-biosupdate +
  # /usr/bin/steamos-polkit-helpers/* — the same paths the AUR
  # gamescope-session-steam-git installs. Leaving it in place produces
  # "exists in filesystem (owned by jupiter-hw-support)" file conflicts during
  # the AUR install. gamescope-session-steam-git ships its own replacements
  # for everything jupiter-hw-support provides, so removing it is safe.
  local cachyos_provider=false
  if literal_installed "gamescope-session-cachyos"; then
    cachyos_provider=true
    packages_to_remove+=("gamescope-session-cachyos")
    info "Detected gamescope-session-cachyos — will remove so AUR build can run"
  fi
  if literal_installed "jupiter-hw-support"; then
    packages_to_remove+=("jupiter-hw-support")
    info "Will also remove jupiter-hw-support (replaced by gamescope-session-steam-git)"
  fi

  if $cachyos_provider || (! literal_installed "gamescope-session-git" && ! literal_installed "gamescope-session"); then
    aur_packages+=("gamescope-session-git")
  fi

  local steam_scripts_missing=false
  local -a required_steam_scripts=(
    "/usr/bin/steamos-session-select"
    "/usr/bin/steamos-update"
    "/usr/bin/jupiter-biosupdate"
    "/usr/bin/steamos-select-branch"
  )

  for script in "${required_steam_scripts[@]}"; do
    if [[ ! -f "$script" ]]; then
      steam_scripts_missing=true
      break
    fi
  done

  if $cachyos_provider || ! literal_installed "gamescope-session-steam-git"; then
    if literal_installed "gamescope-session-steam"; then
      warn "gamescope-session-steam (non-git) is installed but missing Steam compatibility scripts"
      info "The -git version from ChimeraOS includes required scripts:"
      info "  - steamos-session-select, steamos-update, jupiter-biosupdate, steamos-select-branch"
      packages_to_remove+=("gamescope-session-steam")
    fi
    aur_packages+=("gamescope-session-steam-git")
  elif $steam_scripts_missing; then
    warn "gamescope-session-steam-git is installed but Steam compatibility scripts are missing!"
    info "Will reinstall package to restore missing files:"
    for script in "${required_steam_scripts[@]}"; do
      if [[ ! -f "$script" ]]; then
        info "  - Missing: $script"
      fi
    done
    packages_to_remove+=("gamescope-session-steam-git")
    aur_packages+=("gamescope-session-steam-git")
  fi

  # Clean stale AUR git caches
  local aur_cache_helper=""
  if command -v yay >/dev/null 2>&1; then
    aur_cache_helper="yay"
  elif command -v paru >/dev/null 2>&1; then
    aur_cache_helper="paru"
  fi
  if [[ -n "$aur_cache_helper" ]]; then
    local pkg_cache
    for pkg in gamescope-session-git gamescope-session-steam-git; do
      pkg_cache="$HOME/.cache/$aur_cache_helper/$pkg"
      if [[ -d "$pkg_cache" ]]; then
        info "Clearing AUR build cache for $pkg..."
        rm -rf "$pkg_cache"
      fi
    done
  fi

  if ((${#aur_packages[@]})); then
    echo ""
    echo "  The following AUR packages are required for ChimeraOS session:"
    for pkg in "${aur_packages[@]}"; do
      echo "    - $pkg"
    done
    if ((${#packages_to_remove[@]})); then
      echo ""
      echo "  The following packages need to be replaced:"
      for pkg in "${packages_to_remove[@]}"; do
        echo "    - $pkg (will be removed)"
      done
    fi
    echo ""

    local aur_helper=""
    if command -v yay >/dev/null 2>&1 && check_aur_helper_functional yay; then
      aur_helper="yay"
    elif command -v paru >/dev/null 2>&1 && check_aur_helper_functional paru; then
      aur_helper="paru"
    fi

    if [[ -n "$aur_helper" ]]; then
      read -p "Install ChimeraOS session packages with $aur_helper? [Y/n]: " -n 1 -r
      echo
      if [[ ! $REPLY =~ ^[Nn]$ ]]; then
        if ((${#packages_to_remove[@]})); then
          info "Removing conflicting packages: ${packages_to_remove[*]}"
          sudo pacman -Rdd --noconfirm "${packages_to_remove[@]}" || {
            warn "Failed to remove old packages, trying to continue anyway..."
          }
        fi

        info "Installing ChimeraOS gamescope-session packages..."
        # Force AUR origin with `aur/` prefix. Without it, paru/yay will resolve
        # these names to gamescope-session-cachyos (a CachyOS-repo package that
        # declares Provides=gamescope-session-git,gamescope-session-steam-git)
        # and silently install that instead — which does NOT ship
        # /usr/share/gamescope-session-plus/gamescope-session-plus, so the
        # session wrapper exits immediately and plasmalogin autologin loops.
        local -a aur_qualified=()
        for pkg in "${aur_packages[@]}"; do
          aur_qualified+=("aur/${pkg}")
        done
        # --overwrite belt-and-suspenders for any stale file from a partial
        # prior run that wasn't removed by the packages_to_remove step above.
        local overwrite_flags="--overwrite '/usr/bin/steamos-polkit-helpers/*' --overwrite '/usr/bin/jupiter-biosupdate' --overwrite '/usr/bin/steamos-update' --overwrite '/usr/bin/steamos-select-branch' --overwrite '/usr/bin/steamos-session-select'"

        # Pre-flight: confirm AUR is reachable before paru/yay tries to clone.
        # paru reports the underlying git failure ("Empty reply from server")
        # without retrying, so a transient AUR outage kills the whole install.
        # Probe explicitly so we can fail fast with a clear message OR retry.
        local aur_reachable=false
        for probe in 1 2 3; do
          if curl -sSf --max-time 10 -o /dev/null "https://aur.archlinux.org/" 2>/dev/null; then
            aur_reachable=true
            break
          fi
          warn "AUR not reachable (attempt $probe/3) — waiting 10s..."
          sleep 10
        done
        if ! $aur_reachable; then
          err "Cannot reach https://aur.archlinux.org/ after 3 attempts."
          err "AUR may be having an outage, or your network/DNS/firewall is blocking it."
          err "Try again later: $aur_helper -S ${aur_qualified[*]}"
          die "Aborting — AUR build cannot proceed without aur.archlinux.org"
        fi

        # Retry the AUR install itself in case the clone fails mid-build
        # (paru/yay don't retry transient git clone failures internally).
        local install_ok=false
        for attempt in 1 2 3; do
          if [[ "$aur_helper" == "yay" ]]; then
            if $aur_helper -S --needed --noconfirm --answeredit None --answerclean None --answerdiff None $overwrite_flags "${aur_qualified[@]}"; then
              install_ok=true
              break
            fi
          else
            if $aur_helper -S --needed --noconfirm --skipreview $overwrite_flags "${aur_qualified[@]}"; then
              install_ok=true
              break
            fi
          fi
          if [[ $attempt -lt 3 ]]; then
            warn "AUR install attempt $attempt/3 failed — retrying in 15s..."
            sleep 15
          fi
        done
        if ! $install_ok; then
          err "Failed to install gamescope-session packages after 3 attempts"
          warn "You may need to install them manually: $aur_helper -S ${aur_qualified[*]}"
        fi

        # Verify the AUR build actually landed — if pacman silently picked
        # the cachyos provider, /usr/share/gamescope-session-plus/gamescope-session-plus
        # will be missing and the gaming session will black-screen on autologin.
        if [[ ! -x /usr/share/gamescope-session-plus/gamescope-session-plus ]]; then
          err "AUR build appears to have been skipped — gamescope-session-plus is missing."
          if pacman -Qi gamescope-session-cachyos &>/dev/null; then
            err "gamescope-session-cachyos is installed and shadowed the AUR build."
            err "Run: sudo pacman -Rdd gamescope-session-cachyos && $aur_helper -S aur/gamescope-session-git aur/gamescope-session-steam-git"
          fi
          die "Cannot continue — session launcher /usr/share/gamescope-session-plus/gamescope-session-plus not found"
        fi
      fi
    else
      warn "No AUR helper found (yay/paru). Please install manually:"
      if ((${#packages_to_remove[@]})); then
        echo "    sudo pacman -Rns ${packages_to_remove[*]}"
      fi
      echo "    yay -S ${aur_packages[*]}"
      echo ""
      read -r -p "Press Enter to continue after installing, or Ctrl+C to abort..."
    fi
  else
    info "ChimeraOS gamescope-session packages already installed (correct -git versions)"
  fi

  # Prevent distro repos (e.g. CachyOS) from replacing -git packages on system upgrades.
  # gamescope-session-cachyos is added here too: it declares Provides+Conflicts on
  # the -git names, so a plain `pacman -Syu` would otherwise offer to swap our
  # AUR build out for the repo version on every system update.
  info "Ensuring gamescope-session -git packages are protected from replacement..."
  local ignore_pkgs=("gamescope-session-git" "gamescope-session-steam-git" "gamescope-session-cachyos")
  local pacman_conf="/etc/pacman.conf"
  for pkg in "${ignore_pkgs[@]}"; do
    if grep -q "^IgnorePkg" "$pacman_conf"; then
      if ! grep -q "$pkg" "$pacman_conf"; then
        sudo sed -i "s/^IgnorePkg\s*=\(.*\)/IgnorePkg =\1 $pkg/" "$pacman_conf"
        info "Added $pkg to IgnorePkg in pacman.conf"
      fi
    else
      if grep -q "^#IgnorePkg" "$pacman_conf"; then
        sudo sed -i "s/^#IgnorePkg\s*=.*/IgnorePkg   = $pkg/" "$pacman_conf"
        info "Enabled IgnorePkg with $pkg in pacman.conf"
      else
        sudo sed -i "/^\[options\]/a IgnorePkg   = $pkg" "$pacman_conf"
        info "Added IgnorePkg with $pkg to pacman.conf"
      fi
    fi
  done

  info "Setting up NetworkManager integration..."
  if systemctl is-active --quiet iwd; then
    info "Detected iwd is active - configuring NetworkManager to use iwd backend..."
    sudo mkdir -p /etc/NetworkManager/conf.d
    sudo tee /etc/NetworkManager/conf.d/10-iwd-backend.conf > /dev/null << 'NM_IWD_CONF'
[device]
wifi.backend=iwd
wifi.scan-rand-mac-address=no

[main]
plugins=ifupdown,keyfile

[ifupdown]
managed=false

[connection]
connection.autoconnect-slaves=0
NM_IWD_CONF
    info "Created NetworkManager iwd backend configuration"
  fi

  if systemctl is-active --quiet systemd-networkd; then
    info "Detected systemd-networkd - configuring NetworkManager to avoid conflicts..."
    sudo mkdir -p /etc/NetworkManager/conf.d
    sudo tee /etc/NetworkManager/conf.d/20-unmanaged-systemd.conf > /dev/null << 'NM_UNMANAGED'
[keyfile]
unmanaged-devices=interface-name:en*;interface-name:eth*
NM_UNMANAGED
    info "Configured NetworkManager to not manage ethernet interfaces"
  fi

  local nm_start_script="/usr/local/bin/gamescope-nm-start"
  sudo tee "$nm_start_script" > /dev/null << 'NM_START'
#!/bin/bash
NM_MARKER="/tmp/.gamescope-started-nm"
LOG_TAG="gamescope-nm"

log() { logger -t "$LOG_TAG" "$*"; echo "$*"; }

if ! systemctl is-active --quiet NetworkManager.service; then
    log "Starting NetworkManager service..."
    systemctl start NetworkManager.service
    if [ $? -eq 0 ]; then
        touch "$NM_MARKER"
        log "NetworkManager started successfully"
    else
        log "ERROR: Failed to start NetworkManager"
        exit 1
    fi
    log "Waiting for NetworkManager to initialize..."
    for i in {1..20}; do
        if nmcli general status &>/dev/null; then
            log "NetworkManager ready after ${i} attempts"
            break
        fi
        sleep 0.5
    done
    if nmcli general status 2>/dev/null | grep -q "connected"; then
        log "Network connected and ready"
    else
        log "WARNING: NetworkManager running but not connected"
    fi
else
    log "NetworkManager already running"
fi
nmcli general status 2>/dev/null || log "WARNING: nmcli status check failed"
NM_START
  sudo chmod +x "$nm_start_script"

  local nm_stop_script="/usr/local/bin/gamescope-nm-stop"
  sudo tee "$nm_stop_script" > /dev/null << 'NM_STOP'
#!/bin/bash
NM_MARKER="/tmp/.gamescope-started-nm"
LOG_TAG="gamescope-nm"
log() { logger -t "$LOG_TAG" "$*"; echo "$*"; }

if [ -f "$NM_MARKER" ]; then
    rm -f "$NM_MARKER"
    if systemctl is-active --quiet NetworkManager.service; then
        log "Stopping NetworkManager service..."
        systemctl stop NetworkManager.service 2>/dev/null || true
        sleep 1
    fi

    log "Restarting iwd to restore WiFi..."
    systemctl restart iwd.service 2>/dev/null || true
    sleep 3

    WIFI_IFACE=$(iw dev 2>/dev/null | awk '/Interface/{print $2; exit}')
    if [ -z "$WIFI_IFACE" ]; then
        WIFI_IFACE=$(ls /sys/class/net/ 2>/dev/null | grep -E '^wl' | head -1)
    fi

    if [ -n "$WIFI_IFACE" ]; then
        if iwctl station "$WIFI_IFACE" show 2>/dev/null | grep -qi "connected"; then
            log "WiFi restored on $WIFI_IFACE"
        else
            log "Triggering WiFi scan on $WIFI_IFACE..."
            iwctl station "$WIFI_IFACE" scan 2>/dev/null || true
            sleep 3
            if iwctl station "$WIFI_IFACE" show 2>/dev/null | grep -qi "connected"; then
                log "WiFi connected on $WIFI_IFACE after scan"
            else
                log "WiFi on $WIFI_IFACE may need manual reconnection via iwctl"
            fi
        fi
    else
        log "No wireless interface found - skipping WiFi verification"
    fi
else
    log "No marker file found - NetworkManager was not started by gaming session"
fi
NM_STOP
  sudo chmod +x "$nm_stop_script"
  info "Created NetworkManager start/stop scripts"

  local steam_mount_script="/usr/local/bin/steam-library-mount"
  info "Creating Steam library drive mount script..."
  sudo tee "$steam_mount_script" > /dev/null << 'STEAM_MOUNT'
#!/bin/bash
LOG_TAG="steam-library-mount"
MOUNT_BASE="/run/media/$USER"

log() { logger -t "$LOG_TAG" "$*"; }

check_steam_library() {
    local mount_point="$1"
    if [[ -d "$mount_point/steamapps" ]] || \
       [[ -d "$mount_point/SteamLibrary/steamapps" ]] || \
       [[ -d "$mount_point/SteamLibrary" ]] || \
       [[ -f "$mount_point/libraryfolder.vdf" ]] || \
       [[ -f "$mount_point/steamapps/libraryfolder.vdf" ]] || \
       [[ -f "$mount_point/SteamLibrary/libraryfolder.vdf" ]]; then
        return 0
    fi
    return 1
}

handle_device() {
    local device="$1"
    local part_name
    part_name=$(basename "$device")

    log "Checking device: $device"

    if findmnt -n "$device" &>/dev/null; then
        local existing_mount
        existing_mount=$(findmnt -n -o TARGET "$device" 2>/dev/null)
        if [[ -n "$existing_mount" ]] && check_steam_library "$existing_mount"; then
            log "Steam library already mounted at $existing_mount"
        else
            log "Device $device mounted at $existing_mount (no Steam library)"
        fi
        return
    fi

    [[ "$device" =~ [0-9]$ ]] || { log "Skipping whole disk: $device"; return; }

    local fstype
    fstype=$(lsblk -n -o FSTYPE --nodeps "$device" 2>/dev/null)
    case "$fstype" in
        ext4|ext3|ext2|btrfs|xfs|ntfs|vfat|exfat|f2fs) ;;
        crypto_LUKS) log "Skipping encrypted: $device"; return ;;
        swap) log "Skipping swap: $device"; return ;;
        "") log "Skipping $device - no filesystem"; return ;;
        *) log "Skipping $device - unsupported filesystem: $fstype"; return ;;
    esac

    if ! command -v udisksctl &>/dev/null; then
        log "udisksctl not found - cannot mount $device"
        return
    fi

    log "Attempting to mount $device..."
    local mount_output
    mount_output=$(udisksctl mount -b "$device" --no-user-interaction 2>&1)
    local mount_rc=$?

    if [[ $mount_rc -ne 0 ]]; then
        log "Could not mount $device: $mount_output"
        return
    fi

    local mount_point
    mount_point=$(findmnt -n -o TARGET "$device" 2>/dev/null)

    if [[ -z "$mount_point" ]]; then
        log "Could not determine mount point for $device"
        return
    fi

    if check_steam_library "$mount_point"; then
        log "Steam library found on $device at $mount_point - keeping mounted"
    else
        log "No Steam library on $device - unmounting"
        udisksctl unmount -b "$device" --no-user-interaction 2>/dev/null
    fi
}

log "Starting Steam library drive monitor..."

shopt -s nullglob
for dev in /dev/sd*[0-9]* /dev/nvme*p[0-9]*; do
    [[ -b "$dev" ]] && handle_device "$dev"
done
shopt -u nullglob

log "Initial device scan complete, watching for new devices..."

udevadm monitor --kernel --subsystem-match=block 2>/dev/null | while read -r line; do
    if [[ "$line" =~ ^KERNEL.*[[:space:]]add[[:space:]]+.*/([^/[:space:]]+)[[:space:]]+\(block\)$ ]]; then
        dev_name="${BASH_REMATCH[1]}"
        dev_path="/dev/$dev_name"
        if [[ "$dev_name" =~ [0-9]$ ]] && [[ -b "$dev_path" ]]; then
            sleep 1
            handle_device "$dev_path"
        fi
    fi
done
STEAM_MOUNT
  sudo chmod +x "$steam_mount_script"
  info "Created $steam_mount_script"

  local polkit_rules="/etc/polkit-1/rules.d/50-gamescope-networkmanager.rules"

  if sudo test -f "$polkit_rules"; then
    info "Polkit rules already exist at $polkit_rules"
  else
    info "Creating Polkit rules for NetworkManager D-Bus access..."
    sudo mkdir -p /etc/polkit-1/rules.d

    if sudo tee "$polkit_rules" > /dev/null << 'POLKIT_RULES'
polkit.addRule(function(action, subject) {
    if ((action.id == "org.freedesktop.NetworkManager.enable-disable-network" ||
         action.id == "org.freedesktop.NetworkManager.enable-disable-wifi" ||
         action.id == "org.freedesktop.NetworkManager.network-control" ||
         action.id == "org.freedesktop.NetworkManager.wifi.scan" ||
         action.id == "org.freedesktop.NetworkManager.settings.modify.system" ||
         action.id == "org.freedesktop.NetworkManager.settings.modify.own" ||
         action.id == "org.freedesktop.NetworkManager.settings.modify.hostname") &&
        subject.isInGroup("wheel")) {
        return polkit.Result.YES;
    }
});
POLKIT_RULES
    then
      sudo chmod 644 "$polkit_rules"
      info "Polkit rules created successfully"
      sudo systemctl restart polkit.service 2>/dev/null || true
    else
      err "Failed to create polkit rules file"
    fi
  fi

  local udisks_polkit="/etc/polkit-1/rules.d/50-udisks-gaming.rules"

  if sudo test -f "$udisks_polkit"; then
    info "Udisks2 polkit rules already exist at $udisks_polkit"
  else
    info "Creating Polkit rules for external drive auto-mount..."
    sudo mkdir -p /etc/polkit-1/rules.d
    if sudo tee "$udisks_polkit" > /dev/null << 'UDISKS_POLKIT'
polkit.addRule(function(action, subject) {
    if ((action.id == "org.freedesktop.udisks2.filesystem-mount" ||
         action.id == "org.freedesktop.udisks2.filesystem-mount-system" ||
         action.id == "org.freedesktop.udisks2.filesystem-unmount-others" ||
         action.id == "org.freedesktop.udisks2.encrypted-unlock" ||
         action.id == "org.freedesktop.udisks2.power-off-drive") &&
        subject.isInGroup("wheel")) {
        return polkit.Result.YES;
    }
});
UDISKS_POLKIT
    then
      sudo chmod 644 "$udisks_polkit"
      info "Udisks2 polkit rules created successfully"
      sudo systemctl restart polkit.service 2>/dev/null || true
    else
      err "Failed to create udisks2 polkit rules"
    fi
  fi

  info "Creating gamescope-session-plus configuration..."
  local env_dir="${user_home}/.config/environment.d"
  local gamescope_conf="${env_dir}/gamescope-session-plus.conf"

  mkdir -p "$env_dir"

  local output_connector=""
  [[ -n "$monitor_output" ]] && output_connector="OUTPUT_CONNECTOR=$monitor_output"

  local is_nvidia=false
  local nvidia_device_id=""
  if [[ "$dgpu_type" == "NVIDIA" ]]; then
    is_nvidia=true
    nvidia_device_id=$(/usr/bin/lspci -nn | grep -i nvidia | grep -oP '\[10de:\K[0-9a-fA-F]+' | head -1)
    if [ "$monitor_width" -gt 2560 ]; then
      monitor_width=2560
    fi
    if [ "$monitor_height" -gt 1440 ]; then
      monitor_height=1440
    fi
  fi

  if $is_nvidia; then
    local vulkan_adapter=""
    [[ -n "$nvidia_device_id" ]] && vulkan_adapter="VULKAN_ADAPTER=10de:${nvidia_device_id}"
    cat > "$gamescope_conf" << GAMESCOPE_CONF
SCREEN_WIDTH=${monitor_width}
SCREEN_HEIGHT=${monitor_height}
CUSTOM_REFRESH_RATES=${monitor_refresh}
${output_connector}
${vulkan_adapter}
GBM_BACKEND=nvidia-drm
STEAM_ALLOW_DRIVE_UNMOUNT=1
FCITX_NO_WAYLAND_DIAGNOSE=1
SDL_VIDEO_MINIMIZE_ON_FOCUS_LOSS=0
GAMESCOPE_CONF
  else
    cat > "$gamescope_conf" << GAMESCOPE_CONF
SCREEN_WIDTH=${monitor_width}
SCREEN_HEIGHT=${monitor_height}
CUSTOM_REFRESH_RATES=${monitor_refresh}
${output_connector}
ADAPTIVE_SYNC=1
ENABLE_GAMESCOPE_HDR=1
STEAM_ALLOW_DRIVE_UNMOUNT=1
FCITX_NO_WAYLAND_DIAGNOSE=1
SDL_VIDEO_MINIMIZE_ON_FOCUS_LOSS=0
GAMESCOPE_CONF
  fi

  info "Created $gamescope_conf"

  info "Creating NVIDIA gamescope wrapper..."
  local nvidia_wrapper_dir="/usr/local/lib/gamescope-nvidia"
  local nvidia_wrapper="${nvidia_wrapper_dir}/gamescope"

  sudo mkdir -p "$nvidia_wrapper_dir"
  sudo tee "$nvidia_wrapper" > /dev/null << 'NVIDIA_WRAPPER'
#!/bin/bash
EXTRA_ARGS=""
if /usr/bin/gamescope --help 2>&1 | grep -q "force-composition"; then
    EXTRA_ARGS="--force-composition"
fi
exec /usr/bin/gamescope $EXTRA_ARGS "$@"
NVIDIA_WRAPPER

  sudo chmod +x "$nvidia_wrapper"
  info "Created $nvidia_wrapper"

  info "Creating NetworkManager session wrapper..."
  local nm_wrapper="/usr/local/bin/gamescope-session-nm-wrapper"

  sudo tee "$nm_wrapper" > /dev/null << 'NM_WRAPPER'
#!/bin/bash
log() { logger -t gamescope-wrapper "$*"; echo "$*"; }

enable_performance_mode() {
    log "Enabling performance mode..."

    for gov in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
        echo performance > "$gov" 2>/dev/null && log "CPU governor set to performance"
        break
    done
    for gov in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
        echo performance > "$gov" 2>/dev/null
    done

    if command -v nvidia-smi &>/dev/null; then
        sudo -n nvidia-smi -pm 1 2>/dev/null && log "NVIDIA persistence mode enabled"

        local max_power
        max_power=$(nvidia-smi --query-gpu=power.max_limit --format=csv,noheader,nounits 2>/dev/null | head -1 | cut -d'.' -f1)
        if [[ -n "$max_power" && "$max_power" -gt 0 ]]; then
            sudo -n nvidia-smi -pl "$max_power" 2>/dev/null && log "NVIDIA power limit set to ${max_power}W"
        fi

        for nvidia_pci in /sys/bus/pci/devices/*/power/control; do
            if [[ -f "${nvidia_pci%/power/control}/driver" ]]; then
                local drv=$(basename "$(readlink -f "${nvidia_pci%/power/control}/driver")" 2>/dev/null)
                if [[ "$drv" == "nvidia" ]]; then
                    echo on > "$nvidia_pci" 2>/dev/null && log "NVIDIA runtime suspend disabled"
                fi
            fi
        done
    fi

    if command -v powerprofilesctl &>/dev/null; then
        powerprofilesctl set performance 2>/dev/null && log "Power profile set to performance"
    fi
}

restore_balanced_mode() {
    log "Restoring balanced mode..."

    for gov in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
        echo powersave > "$gov" 2>/dev/null
    done

    if command -v nvidia-smi &>/dev/null; then
        local default_power
        default_power=$(nvidia-smi --query-gpu=power.default_limit --format=csv,noheader,nounits 2>/dev/null | head -1 | cut -d'.' -f1)
        if [[ -n "$default_power" && "$default_power" -gt 0 ]]; then
            sudo -n nvidia-smi -pl "$default_power" 2>/dev/null
        fi

        for nvidia_pci in /sys/bus/pci/devices/*/power/control; do
            if [[ -f "${nvidia_pci%/power/control}/driver" ]]; then
                local drv=$(basename "$(readlink -f "${nvidia_pci%/power/control}/driver")" 2>/dev/null)
                if [[ "$drv" == "nvidia" ]]; then
                    echo auto > "$nvidia_pci" 2>/dev/null
                fi
            fi
        done

        sudo -n nvidia-smi -pm 0 2>/dev/null
    fi

    if command -v powerprofilesctl &>/dev/null; then
        powerprofilesctl set balanced 2>/dev/null
    fi

    log "Balanced mode restored"
}

cleanup() {
    pkill -f steam-library-mount 2>/dev/null || true
    pkill -f gaming-keybind-monitor 2>/dev/null || true
    sudo -n /usr/local/bin/gamescope-nm-stop 2>/dev/null || true
    restore_balanced_mode
    rm -f /tmp/.gaming-session-active
}
trap cleanup EXIT INT TERM

enable_performance_mode

if /usr/bin/lspci 2>/dev/null | grep -qi nvidia; then
    export PATH="/usr/local/lib/gamescope-nvidia:$PATH"
fi

sudo -n /usr/local/bin/gamescope-nm-start 2>/dev/null || {
    log "Warning: Could not start NetworkManager"
}

if [[ -x /usr/local/bin/steam-library-mount ]]; then
    /usr/local/bin/steam-library-mount &
    log "Steam library drive monitor started"
else
    log "Warning: steam-library-mount not found"
fi

echo "gamescope" > /tmp/.gaming-session-active

keybind_ok=true

if ! python3 -c "import evdev" 2>/dev/null; then
    log "WARNING: python-evdev not installed"
    keybind_ok=false
fi

if ! groups | grep -qw input; then
    log "WARNING: User not in 'input' group"
    keybind_ok=false
fi

if $keybind_ok && ! ls /dev/input/event* >/dev/null 2>&1; then
    log "WARNING: No input devices accessible"
    keybind_ok=false
fi

if $keybind_ok; then
    /usr/local/bin/gaming-keybind-monitor &
    log "Keybind monitor started (Super+Alt+R to exit)"
else
    log "Keybind monitor NOT started"
fi

export QT_IM_MODULE=steam
export GTK_IM_MODULE=Steam
export STEAM_DISABLE_AUDIO_DEVICE_SWITCHING=1
export STEAM_ENABLE_VOLUME_HANDLER=1

/usr/share/gamescope-session-plus/gamescope-session-plus steam
rc=$?

exit $rc
NM_WRAPPER

  sudo chmod +x "$nm_wrapper"
  info "Created $nm_wrapper"

  info "Creating Wayland session entry..."
  local session_desktop="/usr/share/wayland-sessions/gamescope-session-steam-nm.desktop"

  sudo tee "$session_desktop" > /dev/null << 'SESSION_DESKTOP'
[Desktop Entry]
Name=Gaming Mode (ChimeraOS)
Comment=Steam Big Picture with ChimeraOS gamescope-session
Exec=/usr/local/bin/gamescope-session-nm-wrapper
Type=Application
DesktopNames=gamescope
SESSION_DESKTOP

  info "Created $session_desktop"

  info "Creating session-select script..."
  local os_session_select="/usr/lib/os-session-select"

  sudo tee "$os_session_select" > /dev/null << OS_SESSION_SELECT
#!/bin/bash
rm -f /tmp/.gaming-session-active
sudo -n /usr/local/bin/gaming-session-switch desktop 2>/dev/null || {
  echo "Warning: Failed to update session config"
}
timeout 5 steam -shutdown 2>/dev/null || true
sleep 1
nohup sudo -n systemctl restart ${DM_SERVICE} &>/dev/null &
disown
exit 0
OS_SESSION_SELECT

  sudo chmod +x "$os_session_select"
  info "Created $os_session_select"

  info "Creating switch-to-gaming script..."
  local switch_script="/usr/local/bin/switch-to-gaming"

  sudo tee "$switch_script" > /dev/null << SWITCH_SCRIPT
#!/bin/bash
# Inhibit suspend FIRST
sudo -n systemctl mask --runtime sleep.target suspend.target hibernate.target hybrid-sleep.target 2>/dev/null
sudo -n /usr/local/bin/gaming-session-switch gaming 2>/dev/null || {
  notify-send -u critical -t 3000 "Gaming Mode" "Failed to update session config" 2>/dev/null || true
}
notify-send -u normal -t 2000 "Gaming Mode" "Switching to Gaming Mode..." 2>/dev/null || true
pkill -9 gamescope 2>/dev/null || true
pkill -9 -f gamescope-session 2>/dev/null || true
sleep 1
sudo -n chvt 2 2>/dev/null || true
sleep 0.3
sudo -n systemctl restart ${DM_SERVICE}
SWITCH_SCRIPT

  sudo chmod +x "$switch_script"
  info "Created $switch_script"

  info "Creating switch-to-desktop script..."
  local switch_desktop_script="/usr/local/bin/switch-to-desktop"

  sudo tee "$switch_desktop_script" > /dev/null << SWITCH_DESKTOP
#!/bin/bash
if [[ ! -f /tmp/.gaming-session-active ]]; then
  exit 0
fi
rm -f /tmp/.gaming-session-active

sudo -n systemctl unmask sleep.target suspend.target hibernate.target hybrid-sleep.target 2>/dev/null
sudo -n /usr/local/bin/gaming-session-switch desktop 2>/dev/null || true

# Re-enable Bluetooth
sudo -n /usr/bin/rfkill unblock bluetooth 2>/dev/null || true
sudo -n /usr/bin/systemctl start bluetooth.service 2>/dev/null || true

timeout 5 steam -shutdown 2>/dev/null || true
sleep 1

pkill -TERM gamescope 2>/dev/null || true
pkill -TERM -f gamescope-session 2>/dev/null || true

for _ in {1..6}; do
  pgrep -x gamescope >/dev/null 2>&1 || break
  sleep 0.5
done

if pgrep -x gamescope >/dev/null 2>&1; then
  pkill -9 gamescope 2>/dev/null || true
  pkill -9 -f gamescope-session 2>/dev/null || true
fi

sleep 2

sudo -n chvt 2 2>/dev/null || true
sleep 0.5
sudo -n systemctl stop ${DM_SERVICE} 2>/dev/null || true
sleep 1
sudo -n systemctl start ${DM_SERVICE} &
disown
exit 0
SWITCH_DESKTOP

  sudo chmod +x "$switch_desktop_script"
  info "Created $switch_desktop_script"

  info "Creating gaming mode keybind monitor..."
  local keybind_monitor="/usr/local/bin/gaming-keybind-monitor"

  sudo tee "$keybind_monitor" > /dev/null << 'KEYBIND_MONITOR'
#!/usr/bin/env python3
import sys
import subprocess
import time
import syslog

def log(msg, error=False):
    print(msg, file=sys.stderr if error else sys.stdout)
    syslog.syslog(syslog.LOG_ERR if error else syslog.LOG_INFO, msg)

syslog.openlog("gaming-keybind-monitor", syslog.LOG_PID)

try:
    import evdev
    from evdev import ecodes
except ImportError:
    log("FATAL: python-evdev not installed", error=True)
    sys.exit(1)

def find_keyboards():
    keyboards = []
    devices_checked = 0
    permission_errors = 0
    for path in evdev.list_devices():
        devices_checked += 1
        try:
            device = evdev.InputDevice(path)
            caps = device.capabilities()
            if ecodes.EV_KEY in caps:
                keys = caps[ecodes.EV_KEY]
                if ecodes.KEY_A in keys and ecodes.KEY_R in keys:
                    keyboards.append(device)
        except PermissionError:
            permission_errors += 1
        except Exception:
            continue
    if permission_errors > 0 and not keyboards:
        log(f"FATAL: Permission denied on {permission_errors}/{devices_checked} input devices.", error=True)
    return keyboards

def monitor_keyboards(keyboards):
    meta_pressed = False
    alt_pressed = False
    from selectors import DefaultSelector, EVENT_READ
    selector = DefaultSelector()
    for kbd in keyboards:
        selector.register(kbd, EVENT_READ)
    log(f"Monitoring {len(keyboards)} keyboard(s) for Super+Alt+R...")
    try:
        while True:
            for key, mask in selector.select():
                device = key.fileobj
                try:
                    for event in device.read():
                        if event.type != ecodes.EV_KEY:
                            continue
                        if event.code in (ecodes.KEY_LEFTMETA, ecodes.KEY_RIGHTMETA):
                            meta_pressed = event.value > 0
                        elif event.code in (ecodes.KEY_LEFTALT, ecodes.KEY_RIGHTALT):
                            alt_pressed = event.value > 0
                        elif event.code == ecodes.KEY_R and event.value == 1:
                            if meta_pressed and alt_pressed:
                                log("Super+Alt+R detected! Switching to desktop...")
                                subprocess.run(['/usr/local/bin/switch-to-desktop'])
                                return
                except Exception as e:
                    log(f"Read error: {e}", error=True)
                    continue
    except KeyboardInterrupt:
        pass
    finally:
        selector.close()

def main():
    time.sleep(2)
    keyboards = find_keyboards()
    if not keyboards:
        log("FATAL: No accessible keyboards found!", error=True)
        sys.exit(1)
    monitor_keyboards(keyboards)

if __name__ == '__main__':
    main()
KEYBIND_MONITOR

  sudo chmod +x "$keybind_monitor"
  info "Created $keybind_monitor"

  # Detect the correct KDE session name
  local kde_session_name
  kde_session_name=$(detect_kde_session_name)
  info "Detected KDE session: $kde_session_name"

  info "Creating ${DM_NAME} session switching config..."
  local dm_gaming_conf="${DM_CONF_DIR}/zzz-gaming-session.conf"

  local autologin_user="$current_user"
  if [[ -f "${DM_CONF_DIR}/autologin.conf" ]]; then
    autologin_user=$(sed -n 's/^User=//p' "${DM_CONF_DIR}/autologin.conf" 2>/dev/null | head -1)
    [[ -z "$autologin_user" ]] && autologin_user="$current_user"
  fi

  sudo mkdir -p "${DM_CONF_DIR}"

  # Clean up any drop-in from older script versions (zz-* sorts BEFORE
  # CachyOS's own zz-steamos-autologin.conf, so it would be overridden and
  # the Session= toggle would silently no-op). We now use a zzz- prefix to
  # guarantee precedence over any zz-* file shipped by the distro.
  local stale_drop_in="${DM_CONF_DIR}/zz-gaming-session.conf"
  if [[ -f "$stale_drop_in" ]]; then
    info "Removing stale $stale_drop_in (replaced by zzz- prefixed version)"
    sudo rm -f "$stale_drop_in"
  fi

  sudo tee "$dm_gaming_conf" > /dev/null << DM_GAMING
[Autologin]
User=${autologin_user}
Session=${kde_session_name}
Relogin=true
DM_GAMING

  info "Created $dm_gaming_conf (default session: $kde_session_name)"

  # Remove conflicting Session= from the main conf so .conf.d takes effect
  if [[ -f "${DM_CONF}" ]] && grep -q '^Session=' "${DM_CONF}" 2>/dev/null; then
    info "Removing conflicting Session= from ${DM_CONF} (would override .conf.d)..."
    sudo sed -i '/^Session=.*/d' "${DM_CONF}"
    # Clean up empty [Autologin] section if nothing left in it
    if ! grep -qE '^(User|Session|Relogin)=' "${DM_CONF}" 2>/dev/null; then
      sudo sed -i '/^\[Autologin\]/d' "${DM_CONF}"
    fi
    sudo sed -i '/^[[:space:]]*$/d' "${DM_CONF}"
  fi

  # SDDM's autologin PAM rule requires the user to be in an `autologin` Unix
  # group (pam_succeed_if user ingroup autologin). plasma-login-manager's PAM
  # file uses pam_permit.so instead, so the group isn't checked — but adding
  # the user to it is harmless and keeps the script portable across DMs.
  if [[ "$DM_SERVICE" == "sddm" ]]; then
    if ! groups "$autologin_user" 2>/dev/null | grep -q '\bautologin\b'; then
      info "Adding $autologin_user to autologin group for passwordless session switching (SDDM)..."
      sudo groupadd -f autologin
      sudo usermod -aG autologin "$autologin_user"
      info "Added $autologin_user to autologin group"
    else
      info "User $autologin_user already in autologin group"
    fi
  else
    info "Skipping autologin group setup — not required by ${DM_NAME}"
  fi

  info "Creating session switching helper script..."
  local session_helper="/usr/local/bin/gaming-session-switch"

  sudo tee "$session_helper" > /dev/null << SESSION_HELPER
#!/bin/bash
CONF="${DM_CONF_DIR}/zzz-gaming-session.conf"
MAIN_CONF="${DM_CONF}"

if [[ ! -f "\$CONF" ]]; then
  echo "Error: Config file not found: \$CONF" >&2
  exit 1
fi

case "\$1" in
  gaming)
    sed -i 's/^Session=.*/Session=gamescope-session-steam-nm/' "\$CONF"
    echo "Session set to: gaming mode"
    ;;
  desktop)
    sed -i 's/^Session=.*/Session=${kde_session_name}/' "\$CONF"
    echo "Session set to: desktop mode (KDE Plasma)"
    ;;
  *)
    echo "Usage: \$0 {gaming|desktop}" >&2
    exit 1
    ;;
esac

# Remove conflicting Session= from main conf so .conf.d takes effect
if [[ -f "\$MAIN_CONF" ]] && grep -q '^Session=' "\$MAIN_CONF" 2>/dev/null; then
  sed -i '/^Session=.*/d' "\$MAIN_CONF"
  # Clean up empty [Autologin] section if nothing left in it
  if ! grep -qE '^(User|Session|Relogin)=' "\$MAIN_CONF" 2>/dev/null; then
    sed -i '/^\[Autologin\]/d' "\$MAIN_CONF"
  fi
  sed -i '/^[[:space:]]*$/d' "\$MAIN_CONF"
fi
SESSION_HELPER

  sudo chmod +x "$session_helper"
  info "Created $session_helper"

  local sudoers_session="/etc/sudoers.d/gaming-session-switch"

  if [[ -f "$sudoers_session" ]]; then
    info "Removing old sudoers rules to update..."
    sudo rm -f "$sudoers_session"
  fi

  info "Creating sudoers rules for session switching..."
  sudo mkdir -p /etc/sudoers.d

  if sudo tee "$sudoers_session" > /dev/null << SUDOERS_SWITCH
%video ALL=(ALL) NOPASSWD: /usr/local/bin/gaming-session-switch
%video ALL=(ALL) NOPASSWD: /usr/bin/systemctl restart ${DM_SERVICE}
%video ALL=(ALL) NOPASSWD: /usr/bin/systemctl stop ${DM_SERVICE}
%video ALL=(ALL) NOPASSWD: /usr/bin/systemctl start ${DM_SERVICE}
%video ALL=(ALL) NOPASSWD: /usr/bin/chvt
%video ALL=(ALL) NOPASSWD: /usr/bin/systemctl mask --runtime sleep.target suspend.target hibernate.target hybrid-sleep.target
%video ALL=(ALL) NOPASSWD: /usr/bin/systemctl unmask sleep.target suspend.target hibernate.target hybrid-sleep.target
%wheel ALL=(ALL) NOPASSWD: /usr/bin/systemctl start NetworkManager.service
%wheel ALL=(ALL) NOPASSWD: /usr/bin/systemctl stop NetworkManager.service
%video ALL=(ALL) NOPASSWD: /usr/bin/systemctl start bluetooth.service
%video ALL=(ALL) NOPASSWD: /usr/bin/rfkill unblock bluetooth
%wheel ALL=(ALL) NOPASSWD: /usr/local/bin/gamescope-nm-start
%wheel ALL=(ALL) NOPASSWD: /usr/local/bin/gamescope-nm-stop
%video ALL=(ALL) NOPASSWD: /usr/bin/nvidia-smi -pm *
%video ALL=(ALL) NOPASSWD: /usr/bin/nvidia-smi -pl *
SUDOERS_SWITCH
  then
    sudo chmod 0440 "$sudoers_session"
    info "Sudoers rules created successfully"
  else
    err "Failed to create sudoers file"
  fi

  # Set up KDE Plasma keybinding instead of Hyprland binding
  setup_kde_shortcut "$user_home"

  info "Steam compatibility scripts provided by gamescope-session-steam-git"

  info "Verifying NetworkManager integration..."
  echo ""

  local nm_test_ok=true
  local iwd_was_active=false
  systemctl is-active --quiet iwd.service && iwd_was_active=true

  if ! systemctl is-active --quiet NetworkManager.service; then
    info "Testing NetworkManager startup..."
    if sudo systemctl start NetworkManager.service 2>/dev/null; then
      sleep 2
      if nmcli general status &>/dev/null; then
        info "NetworkManager started successfully"
        if nmcli general status 2>/dev/null | grep -qE "connected|connecting"; then
          info "NetworkManager can see network - Steam network access should work"
        else
          warn "NetworkManager running but shows disconnected"
          warn "This is expected if iwd/systemd-networkd manages your connection"
          info "Steam should still be able to use the network via D-Bus"
        fi
        sudo systemctl stop NetworkManager.service 2>/dev/null || true
        if $iwd_was_active; then
          info "Restoring iwd WiFi connection..."
          sudo systemctl restart iwd.service 2>/dev/null || true
          sleep 2
        fi
      else
        nm_test_ok=false
        err "NetworkManager started but nmcli not responding"
        sudo systemctl stop NetworkManager.service 2>/dev/null || true
        if $iwd_was_active; then
          sudo systemctl restart iwd.service 2>/dev/null || true
        fi
      fi
    else
      nm_test_ok=false
      err "Failed to start NetworkManager for testing"
    fi
  else
    info "NetworkManager already running - integration should work"
  fi

  echo ""
  echo "================================================================"
  echo "  SESSION SWITCHING CONFIGURED (ChimeraOS + KDE Plasma)"
  echo "================================================================"
  echo ""
  echo "  Usage:"
  echo "    - Press Super+Alt+S in KDE Plasma to switch to Gaming Mode"
  echo "    - Press Super+Alt+R in Gaming Mode to return to KDE Plasma"
  echo "    - (Steam's Power > Exit to Desktop also works as fallback)"
  echo ""
  echo "  ChimeraOS packages installed:"
  echo "    - gamescope-session-git (base session framework)"
  echo "    - gamescope-session-steam-git (Steam session)"
  echo ""
  echo "  Files created/modified:"
  echo "    - ~/.config/environment.d/gamescope-session-plus.conf"
  echo "    - /usr/local/bin/gamescope-session-nm-wrapper"
  echo "    - /usr/share/wayland-sessions/gamescope-session-steam-nm.desktop"
  echo "    - /usr/lib/os-session-select"
  echo "    - /usr/local/bin/switch-to-gaming"
  echo "    - /usr/local/bin/switch-to-desktop"
  echo "    - /usr/local/bin/gaming-keybind-monitor (Super+Alt+R)"
  echo "    - /usr/share/applications/switch-to-gaming.desktop"
  echo "    - ~/.config/kglobalshortcutsrc (KDE shortcut added)"
  echo ""
  echo "  NetworkManager integration (Steam network access):"
  echo "    - /usr/local/bin/gamescope-nm-start"
  echo "    - /usr/local/bin/gamescope-nm-stop"
  echo "    - /etc/polkit-1/rules.d/50-gamescope-networkmanager.rules"
  echo "    - /etc/sudoers.d/gaming-session-switch (NM rules added)"

  if [[ -f /etc/NetworkManager/conf.d/10-iwd-backend.conf ]]; then
    echo "    - /etc/NetworkManager/conf.d/10-iwd-backend.conf (iwd backend)"
  fi
  if [[ -f /etc/NetworkManager/conf.d/20-unmanaged-systemd.conf ]]; then
    echo "    - /etc/NetworkManager/conf.d/20-unmanaged-systemd.conf (systemd-networkd coexistence)"
  fi
  echo ""

  if [[ "$nm_test_ok" != "true" ]]; then
    echo "  WARNING: NetworkManager test failed!"
    echo "  Steam may not have network access in Gaming Mode."
    echo ""
    echo "  Troubleshooting:"
    echo "    1. Ensure NetworkManager is installed: pacman -S networkmanager"
    echo "    2. Check if iwd is running: systemctl status iwd"
    echo "    3. Try manually: sudo systemctl start NetworkManager && nmcli general"
    echo "    4. Check logs: journalctl -u NetworkManager -n 50"
    echo ""
  fi

  return 0
}

verify_installation() {
  echo ""
  echo "================================================================"
  echo "  GAMING MODE INSTALLATION VERIFICATION (KDE Plasma)"
  echo "================================================================"
  echo ""

  detect_display_manager
  info "Display manager: ${DM_NAME}"

  local all_ok=true
  local missing_files=()
  local permission_issues=()

  declare -A expected_files=(
    ["/usr/local/bin/gamescope-session-nm-wrapper"]="755:ChimeraOS session with NM wrapper"
    ["/usr/local/lib/gamescope-nvidia/gamescope"]="755:NVIDIA gamescope wrapper (--force-composition)"
    ["/usr/local/bin/gaming-session-switch"]="755:Session switching helper (gaming/desktop)"
    ["/usr/lib/os-session-select"]="755:Steam Exit to Desktop handler"
    ["/usr/local/bin/switch-to-gaming"]="755:KDE Plasma to Gaming Mode switcher"
    ["/usr/local/bin/switch-to-desktop"]="755:Gaming Mode to Desktop switcher (Super+Alt+R)"
    ["/usr/local/bin/gaming-keybind-monitor"]="755:Keybind monitor for Super+Alt+R"
    ["/usr/local/bin/gamescope-nm-start"]="755:NetworkManager start script"
    ["/usr/local/bin/gamescope-nm-stop"]="755:NetworkManager stop script"
    ["/usr/local/bin/steam-library-mount"]="755:Steam library drive auto-mount script"
    ["/usr/bin/steamos-session-select"]="755:Steam compatibility (from AUR package)"
    ["/usr/bin/steamos-update"]="755:Steam compatibility (from AUR package)"
    ["/usr/bin/jupiter-biosupdate"]="755:Steam compatibility (from AUR package)"
    ["/usr/bin/steamos-select-branch"]="755:Steam compatibility (from AUR package)"
    ["/usr/share/wayland-sessions/gamescope-session-steam-nm.desktop"]="644:Wayland session entry"
    ["/usr/share/gamescope-session-plus/gamescope-session-plus"]="755:ChimeraOS session launcher (from AUR)"
    ["/usr/share/applications/switch-to-gaming.desktop"]="644:KDE shortcut desktop entry"
    ["${DM_CONF_DIR}/zzz-gaming-session.conf"]="644:${DM_NAME} session switching config"
    ["/etc/polkit-1/rules.d/50-gamescope-networkmanager.rules"]="644:Polkit NM rules"
    ["/etc/polkit-1/rules.d/50-udisks-gaming.rules"]="644:Polkit udisks2 rules (external drive mount)"
    ["/etc/sudoers.d/gaming-session-switch"]="440:Sudoers rules"
    ["/etc/NetworkManager/conf.d/10-iwd-backend.conf"]="644:NM iwd backend config (optional)"
    ["/etc/NetworkManager/conf.d/20-unmanaged-systemd.conf"]="644:NM systemd coexistence (optional)"
    ["/etc/udev/rules.d/99-gaming-performance.rules"]="644:Udev performance rules"
    ["/etc/sudoers.d/gaming-mode-sysctl"]="440:Performance sudoers"
    ["/etc/security/limits.d/99-gaming-memlock.conf"]="644:Memlock limits"
    ["/etc/pipewire/pipewire.conf.d/10-gaming-latency.conf"]="644:PipeWire low-latency"
    ["/etc/environment.d/99-shader-cache.conf"]="644:Shader cache config"
  )
  echo "  FILE STATUS:"
  echo "  ------------"
  echo ""

  for file in "${!expected_files[@]}"; do
    local expected_perm="${expected_files[$file]%%:*}"
    local description="${expected_files[$file]#*:}"
    local is_optional=false

    [[ "$description" == *"(optional)"* ]] && is_optional=true

    if sudo test -f "$file" 2>/dev/null; then
      local actual_perm
      actual_perm=$(sudo stat -c "%a" "$file" 2>/dev/null)

      if [[ "$actual_perm" == "$expected_perm" ]]; then
        printf "  OK %-55s [%s]\n" "$file" "$actual_perm"
      else
        printf "  !! %-55s [%s] (expected %s)\n" "$file" "$actual_perm" "$expected_perm"
        permission_issues+=("$file: has $actual_perm, expected $expected_perm")
        all_ok=false
      fi
    else
      if $is_optional; then
        printf "  -- %-55s [SKIPPED] %s\n" "$file" "(optional)"
      else
        printf "  XX %-55s [MISSING]\n" "$file"
        missing_files+=("$file: $description")
        all_ok=false
      fi
    fi
  done

  echo ""
  echo "  KDE PLASMA SHORTCUT:"
  echo "  ---------------------"
  local kde_shortcuts="$HOME/.config/kglobalshortcutsrc"
  if [[ -f "$kde_shortcuts" ]]; then
    if grep -q "switch-to-gaming" "$kde_shortcuts" 2>/dev/null; then
      echo "  OK Gaming Mode shortcut (Super+Alt+S) configured in kglobalshortcutsrc"
    else
      echo "  XX Gaming Mode shortcut NOT found in kglobalshortcutsrc"
      echo "     You can add it manually: System Settings > Shortcuts > Custom Shortcuts"
      all_ok=false
    fi
  else
    echo "  !! kglobalshortcutsrc not found - shortcut needs manual setup"
    echo "     Go to System Settings > Shortcuts to add Super+Alt+S"
  fi

  echo ""
  echo "  CHIMERAOS PACKAGES:"
  echo "  -------------------"
  if check_package "gamescope-session-git" || check_package "gamescope-session"; then
    echo "  OK gamescope-session installed"
  else
    echo "  XX gamescope-session NOT installed"
    all_ok=false
  fi
  if check_package "gamescope-session-steam-git" || check_package "gamescope-session-steam"; then
    echo "  OK gamescope-session-steam installed"
  else
    echo "  XX gamescope-session-steam NOT installed"
    all_ok=false
  fi

  echo ""
  echo "  STEAM LIBRARY DRIVE SUPPORT:"
  echo "  -----------------------------"
  if [[ -x "/usr/local/bin/steam-library-mount" ]]; then
    echo "  OK steam-library-mount script installed"
  else
    echo "  XX steam-library-mount NOT found - external Steam libraries will not auto-mount"
    all_ok=false
  fi
  if check_package "udisks2"; then
    echo "  OK udisks2 installed (mount backend)"
  else
    echo "  XX udisks2 NOT installed"
    all_ok=false
  fi
  if sudo test -f "/etc/polkit-1/rules.d/50-udisks-gaming.rules" 2>/dev/null; then
    echo "  OK udisks2 polkit rules configured"
  else
    echo "  XX udisks2 polkit rules NOT found"
    all_ok=false
  fi

  echo ""
  echo "  KEYBIND MONITOR (Super+Alt+R):"
  echo "  ---------------------------------"
  local keybind_ok=true

  if check_package "python-evdev"; then
    echo "  OK python-evdev installed"
  else
    echo "  XX python-evdev NOT installed"
    keybind_ok=false
    all_ok=false
  fi

  if python3 -c "import evdev" 2>/dev/null; then
    echo "  OK python-evdev importable"
  else
    echo "  XX python-evdev cannot be imported"
    keybind_ok=false
    all_ok=false
  fi

  if groups 2>/dev/null | grep -qw input; then
    echo "  OK User in 'input' group"
  else
    echo "  XX User NOT in 'input' group (required for keybind)"
    keybind_ok=false
    all_ok=false
  fi

  if ls /dev/input/event* >/dev/null 2>&1; then
    local test_device
    test_device=$(find /dev/input -name 'event*' -print -quit 2>/dev/null)
    if [[ -r "$test_device" ]]; then
      echo "  OK Can read input devices"
    else
      echo "  XX Cannot read $test_device (permission denied)"
      echo "    (May need to log out/in after adding to input group)"
      keybind_ok=false
      all_ok=false
    fi
  else
    echo "  !! No /dev/input/event* devices found"
  fi

  if $keybind_ok; then
    echo "  -> Super+Alt+R keybind should work"
  else
    echo "  -> Super+Alt+R keybind will NOT work (use Steam > Power > Exit to Desktop)"
  fi

  echo ""
  echo "  USER CONFIG:"
  echo "  ------------"
  local user_conf="$HOME/.config/environment.d/gamescope-session-plus.conf"
  if [[ -f "$user_conf" ]]; then
    echo "  OK gamescope-session-plus.conf exists"
  else
    echo "  XX gamescope-session-plus.conf NOT found"
    all_ok=false
  fi

  echo ""
  echo "  USER GROUPS:"
  echo "  ------------"
  local user_groups
  user_groups=$(groups 2>/dev/null)
  for grp in video input wheel; do
    if echo "$user_groups" | grep -qw "$grp"; then
      printf "  OK User is in '%s' group\n" "$grp"
    else
      printf "  XX User is NOT in '%s' group\n" "$grp"
      all_ok=false
    fi
  done

  echo ""
  echo "  SERVICE STATUS:"
  echo "  ---------------"
  echo "  NetworkManager: $(systemctl is-active NetworkManager.service 2>/dev/null || echo 'inactive') (should be inactive until gaming mode)"
  echo "  iwd:            $(systemctl is-active iwd.service 2>/dev/null || echo 'inactive')"
  echo "  systemd-networkd: $(systemctl is-active systemd-networkd.service 2>/dev/null || echo 'inactive')"
  echo "  polkit:         $(systemctl is-active polkit.service 2>/dev/null || echo 'inactive')"

  echo ""
  echo "  SUDO PERMISSIONS TEST:"
  echo "  ----------------------"
  if sudo -n true 2>/dev/null; then
    echo "  OK sudo -n works (passwordless sudo available)"
    if sudo -n -l /usr/local/bin/gamescope-nm-start &>/dev/null; then
      echo "  OK Can run gamescope-nm-start without password"
    else
      echo "  XX Cannot run gamescope-nm-start without password"
      all_ok=false
    fi
  else
    echo "  !! sudo -n test skipped (requires recent sudo auth)"
    echo "    Run: sudo -v && sudo -n -l /usr/local/bin/gamescope-nm-start"
  fi

  echo ""
  echo "================================================================"
  if $all_ok; then
    echo "  ALL CHECKS PASSED - Gaming Mode should work correctly"
  else
    echo "  SOME ISSUES DETECTED"
    echo ""
    if ((${#missing_files[@]})); then
      echo "  Missing files (${#missing_files[@]}):"
      for f in "${missing_files[@]}"; do
        echo "    - $f"
      done
    fi
    if ((${#permission_issues[@]})); then
      echo ""
      echo "  Permission issues (${#permission_issues[@]}):"
      for p in "${permission_issues[@]}"; do
        echo "    - $p"
      done
    fi
    echo ""
    echo "  Re-run the installer to fix these issues."
  fi
  echo "================================================================"
  echo ""

  $all_ok && return 0 || return 1
}

execute_setup() {
  sudo -k
  sudo -v || die "sudo authentication required"

  validate_environment

  echo ""
  echo "================================================================"
  echo "  SUPER SHIFT S GAMING MODE INSTALLER v${Super_Shift_S_VERSION}"
  echo "  KDE Plasma Edition - Dependencies & GPU Configuration"
  echo "================================================================"
  echo ""

  check_steam_dependencies
  check_nvidia_kernel_params
  install_nvidia_deckmode_env
  setup_requirements
  setup_session_switching

  if [ "$NEEDS_REBOOT" -eq 1 ]; then
    echo ""
    echo "================================================================"
    echo "  IMPORTANT: REBOOT REQUIRED"
    echo "================================================================"
    echo ""
    echo "  Bootloader configuration has been updated (nvidia-drm.modeset=1)."
    echo "  You MUST reboot for the kernel parameter to take effect."
    echo ""
    if [ "$NEEDS_RELOGIN" -eq 1 ]; then
      echo "  Additionally, user groups were updated (video/input/wheel)."
    fi
    echo ""
    read -p "Reboot now? [y/N]: " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
      info "Rebooting..."
      sleep 2
      systemctl reboot
    else
      echo ""
      echo "  Remember to reboot before continuing!"
      echo ""
    fi
  elif [ "$NEEDS_RELOGIN" -eq 1 ]; then
    echo ""
    echo "================================================================"
    echo "  IMPORTANT: LOG OUT REQUIRED"
    echo "================================================================"
    echo ""
    echo "  User groups have been updated. You MUST log out and log back in"
    echo "  for the changes to take effect."
    echo ""
    read -r -p "Press Enter to exit (remember to log out)..."
  else
    echo ""
    echo "================================================================"
    echo "  SETUP COMPLETE"
    echo "================================================================"
    echo ""
    echo "  Dependencies, GPU configuration, and session switching are ready."
    echo ""
    echo "  To switch to Gaming Mode: Press Super+Alt+S"
    echo "  To return to Desktop:     Press Super+Alt+R"
    echo ""
  fi

  echo ""
  read -p "Run installation verification? [Y/n]: " -n 1 -r
  echo
  if [[ ! $REPLY =~ ^[Nn]$ ]]; then
    verify_installation
  fi
}

show_help() {
  echo "Super Shift S Gaming Mode Installer v${Super_Shift_S_VERSION}"
  echo "KDE Plasma Edition (CachyOS)"
  echo ""
  echo "Usage: $0 [OPTIONS]"
  echo ""
  echo "Options:"
  echo "  --help, -h      Show this help message"
  echo "  --verify, -v    Run verification only (check all files and permissions)"
  echo "  --version       Show version number"
  echo ""
  echo "Without options, runs the full installation/setup process."
  echo ""
}

case "${1:-}" in
  --help|-h)
    show_help
    exit 0
    ;;
  --verify|-v)
    echo "Running verification only..."
    verify_installation
    exit $?
    ;;
  --version)
    echo "Super Shift S Gaming Mode Installer v${Super_Shift_S_VERSION}"
    exit 0
    ;;
  "")
    execute_setup
    ;;
  *)
    echo "Unknown option: $1"
    echo "Use --help for usage information."
    exit 1
    ;;
esac
