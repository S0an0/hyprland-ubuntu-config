#!/usr/bin/env bash
set -euo pipefail

script_path="$(readlink -f -- "${BASH_SOURCE[0]}")"
repo_dir="$(cd -- "$(dirname -- "$script_path")" && pwd -P)"
restore_system=true

usage() {
  printf 'Usage: %s [--configs-only]\n' "$0"
  printf '  --configs-only  restore only user configuration (no root prompt)\n'
}

case "${1:-}" in
  '') ;;
  --configs-only) restore_system=false ;;
  -h|--help) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac

if [[ "$(id -u)" -eq 0 ]]; then
  printf 'Run as your normal desktop user, not with sudo.\n' >&2
  exit 1
fi
[[ -f "$repo_dir/hypr/hyprland.conf" ]] || {
  printf 'Incomplete repository: hypr/hyprland.conf is missing.\n' >&2
  exit 1
}

if $restore_system; then
  missing_packages=()
  while IFS= read -r package_name; do
    [[ -z "$package_name" || "$package_name" == \#* ]] && continue
    dpkg-query -W -f='${Status}' "$package_name" 2>/dev/null | grep -q 'install ok installed' \
      || missing_packages+=("$package_name")
  done < "$repo_dir/packages.txt"

  if (( ${#missing_packages[@]} > 0 )); then
    if ! grep -Rqs 'ppa.launchpadcontent.net/cppiber/hyprland' /etc/apt/sources.list /etc/apt/sources.list.d 2>/dev/null; then
      pkexec /usr/bin/add-apt-repository -y ppa:cppiber/hyprland || true
    fi
    pkexec /usr/bin/apt-get update
    pkexec /usr/bin/apt-get install -y "${missing_packages[@]}"
  fi

  if ! command -v swww >/dev/null 2>&1; then
    cargo install --locked --root "$HOME/.local" --version 0.11.2 swww
  fi

  for pam_name in gtklock hyprlock; do
    if [[ -f "$repo_dir/system/pam.d/$pam_name" ]]; then
      pkexec /usr/bin/install -o root -g root -m 0644 \
        "$repo_dir/system/pam.d/$pam_name" "/etc/pam.d/$pam_name"
    fi
  done
fi

for command_name in rsync tar xz; do
  command -v "$command_name" >/dev/null 2>&1 || {
    printf 'Missing command after package setup: %s\n' "$command_name" >&2
    exit 1
  }
done

rollback_dir="$HOME/.local/state/hyprland-restore/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$rollback_dir/config" "$rollback_dir/bin"

config_dirs=(hypr waybar gtklock wlogout alacritty rofi mako fastfetch cava)
for config_name in "${config_dirs[@]}"; do
  if [[ -d "$HOME/.config/$config_name" ]]; then
    mkdir -p "$rollback_dir/config/$config_name"
    rsync -a -- "$HOME/.config/$config_name/" "$rollback_dir/config/$config_name/"
  fi
done
[[ -f "$HOME/.config/starship.toml" ]] \
  && install -m 0644 "$HOME/.config/starship.toml" "$rollback_dir/config/starship.toml"
if [[ -d "$HOME/.local/bin" ]]; then
  rsync -a --include='hypr-*' --exclude='*' \
    "$HOME/.local/bin/" "$rollback_dir/bin/"
fi

for config_name in "${config_dirs[@]}"; do
  source_dir="$repo_dir/$config_name"
  if [[ -d "$source_dir" ]]; then
    mkdir -p "$HOME/.config/$config_name"
    rsync -a --delete -- "$source_dir/" "$HOME/.config/$config_name/"
  fi
done

[[ -f "$repo_dir/starship/starship.toml" ]] \
  && install -m 0644 "$repo_dir/starship/starship.toml" "$HOME/.config/starship.toml"
mkdir -p "$HOME/.local/bin"
rsync -a -- "$repo_dir/bin/" "$HOME/.local/bin/"

safe_extract() {
  local archive="$1"
  local entry
  while IFS= read -r entry; do
    case "$entry" in
      /*|../*|*/../*) printf 'Unsafe path in %s: %s\n' "$archive" "$entry" >&2; return 1 ;;
    esac
  done < <(tar -tJf "$archive")
  tar -xJf "$archive" -C "$HOME"
}

for archive_name in graphite-themes colloid-icons jetbrains-mono-nerd-essential; do
  archive_path="$repo_dir/assets/$archive_name.tar.xz"
  [[ -f "$archive_path" ]] && safe_extract "$archive_path"
done
command -v fc-cache >/dev/null 2>&1 && fc-cache -f >/dev/null 2>&1 || true

pictures_dir="$(xdg-user-dir PICTURES 2>/dev/null || true)"
if [[ -z "$pictures_dir" || "$pictures_dir" == "$HOME" ]]; then
  pictures_dir="$HOME/Pictures"
fi
if [[ -d "$repo_dir/assets/wallpapers" ]]; then
  mkdir -p "$pictures_dir/Wallpapers"
  rsync -a -- "$repo_dir/assets/wallpapers/" "$pictures_dir/Wallpapers/"
fi

desktop_dir="$(xdg-user-dir DESKTOP 2>/dev/null || true)"
if [[ -z "$desktop_dir" || "$desktop_dir" == "$HOME" ]]; then
  desktop_dir="$HOME/Desktop"
fi
if [[ -f "$repo_dir/Шпаргалка-Hyprland.txt" ]]; then
  mkdir -p "$desktop_dir"
  install -m 0644 "$repo_dir/Шпаргалка-Hyprland.txt" \
    "$desktop_dir/Шпаргалка по горячим клавишам Hyprland.txt"
fi

if ! grep -Fqx '# Hyprpuccin terminal integration' "$HOME/.bashrc" 2>/dev/null; then
  printf '\n' >> "$HOME/.bashrc"
  cat "$repo_dir/bashrc.block" >> "$HOME/.bashrc"
fi

mkdir -p "${XDG_CACHE_HOME:-$HOME/.cache}/hyprpuccin"
[[ -f "$repo_dir/state/theme" ]] \
  && install -m 0644 "$repo_dir/state/theme" "${XDG_CACHE_HOME:-$HOME/.cache}/hyprpuccin/theme"

install -m 0755 "$repo_dir/bootstrap/hypr-backup" "$HOME/.local/bin/hypr-backup"
install -m 0755 "$repo_dir/bootstrap/hypr-restore" "$HOME/.local/bin/hypr-restore"
"$HOME/.local/bin/hypr-theme" apply || true

if command -v hyprctl >/dev/null 2>&1 && hyprctl instances -j 2>/dev/null | jq -e 'length > 0' >/dev/null 2>&1; then
  hyprctl reload >/dev/null
  pkill -TERM -x waybar 2>/dev/null || true
  sleep 1
  hyprctl dispatch exec waybar >/dev/null
  hyprctl dispatch exec "$HOME/.local/bin/hypr-desktop-widgets" >/dev/null
  makoctl reload 2>/dev/null || true
  "$HOME/.local/bin/hypr-wallpaper-next" >/dev/null 2>&1 || true
fi

printf '\nHyprland settings restored.\n'
printf 'Rollback copy: %s\n' "$rollback_dir"
printf 'On a fresh Ubuntu installation, log out and select Hyprland in GDM.\n'
