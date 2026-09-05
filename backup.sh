#!/usr/bin/env bash
set -euo pipefail

script_path="$(readlink -f -- "${BASH_SOURCE[0]}")"
repo_dir="$(cd -- "$(dirname -- "$script_path")" && pwd -P)"
push_changes=true
[[ "${1:-}" == "--no-push" ]] && push_changes=false

if [[ -n "${1:-}" && "${1:-}" != "--no-push" ]]; then
  printf 'Usage: %s [--no-push]\n' "$0" >&2
  exit 2
fi

for command_name in git rsync tar xz; do
  command -v "$command_name" >/dev/null 2>&1 || {
    printf 'Missing command: %s\n' "$command_name" >&2
    exit 1
  }
done

sync_config() {
  local name="$1"
  local source_dir="$HOME/.config/$name"
  local target_dir="$repo_dir/$name"
  [[ -d "$source_dir" ]] || return 0
  mkdir -p "$target_dir"
  case "$name" in
    hypr)
      rsync -a --delete --exclude='pam-hyprlock*' \
        -- "$source_dir/" "$target_dir/"
      ;;
    fastfetch)
      rsync -a --delete \
        --exclude='config-compact.jsonc' \
        --exclude='config-pokemon.jsonc' \
        --exclude='config-v2.jsonc' \
        --exclude='ubuntu.png' \
        -- "$source_dir/" "$target_dir/"
      ;;
    cava)
      rsync -a --delete --exclude='shaders/' --exclude='themes/' \
        -- "$source_dir/" "$target_dir/"
      ;;
    *)
      rsync -a --delete -- "$source_dir/" "$target_dir/"
      ;;
  esac
}

for config_name in hypr waybar gtklock wlogout alacritty rofi mako fastfetch cava; do
  sync_config "$config_name"
done

active_theme="frappe"
theme_state="${XDG_CACHE_HOME:-$HOME/.cache}/hyprpuccin/theme"
if [[ -r "$theme_state" ]]; then
  IFS= read -r active_theme < "$theme_state"
fi
[[ "$active_theme" == "frappe" || "$active_theme" == "latte" ]] || active_theme="frappe"

ln -sfn "themes/$active_theme.toml" "$repo_dir/alacritty/colors.toml"
ln -sfn "themes/$active_theme.conf" "$repo_dir/hypr/theme.conf"
ln -sfn "themes/$active_theme" "$repo_dir/mako/config"
ln -sfn "themes/$active_theme.rasi" "$repo_dir/rofi/theme.rasi"
ln -sfn "themes/$active_theme.css" "$repo_dir/waybar/theme.css"

mkdir -p "$repo_dir/starship" "$repo_dir/bin" "$repo_dir/system/pam.d" \
  "$repo_dir/assets/wallpapers" "$repo_dir/state"

[[ -f "$HOME/.config/starship.toml" ]] \
  && install -m 0644 "$HOME/.config/starship.toml" "$repo_dir/starship/starship.toml"

rsync -a --delete \
  --exclude='hypr-backup' --exclude='hypr-restore' \
  --include='hypr-*' --exclude='*' \
  "$HOME/.local/bin/" "$repo_dir/bin/"

pictures_dir="$(xdg-user-dir PICTURES 2>/dev/null || true)"
if [[ -z "$pictures_dir" || "$pictures_dir" == "$HOME" ]]; then
  pictures_dir="$HOME/Pictures"
fi
if [[ -d "$pictures_dir/Wallpapers" ]]; then
  rsync -a --delete -- "$pictures_dir/Wallpapers/" "$repo_dir/assets/wallpapers/"
fi

desktop_dir="$(xdg-user-dir DESKTOP 2>/dev/null || true)"
if [[ -z "$desktop_dir" || "$desktop_dir" == "$HOME" ]]; then
  desktop_dir="$HOME/Desktop"
fi
cheat_sheet="$desktop_dir/Шпаргалка по горячим клавишам Hyprland.txt"
[[ -f "$cheat_sheet" ]] \
  && install -m 0644 "$cheat_sheet" "$repo_dir/Шпаргалка-Hyprland.txt"

for pam_name in gtklock hyprlock; do
  [[ -r "/etc/pam.d/$pam_name" ]] \
    && install -m 0644 "/etc/pam.d/$pam_name" "$repo_dir/system/pam.d/$pam_name"
done

make_archive() {
  local target="$1"
  shift
  local temporary="$target.part"
  tar -C "$HOME" -cJf "$temporary" "$@"
  mv -- "$temporary" "$target"
}

mapfile -t graphite_paths < <(find "$HOME/.themes" -mindepth 1 -maxdepth 1 -type d \
  -name 'Graphite-teal-*' -printf '.themes/%f\n' | sort)
(( ${#graphite_paths[@]} > 0 )) \
  && make_archive "$repo_dir/assets/graphite-themes.tar.xz" "${graphite_paths[@]}"

mapfile -t colloid_paths < <(find "$HOME/.local/share/icons" -mindepth 1 -maxdepth 1 -type d \
  -name 'Colloid-Orange-Catppuccin*' -printf '.local/share/icons/%f\n' | sort)
(( ${#colloid_paths[@]} > 0 )) \
  && make_archive "$repo_dir/assets/colloid-icons.tar.xz" "${colloid_paths[@]}"

font_root='.local/share/fonts/JetBrainsMonoNerd'
font_paths=(
  "$font_root/JetBrainsMonoNerdFont-Regular.ttf"
  "$font_root/JetBrainsMonoNerdFont-Bold.ttf"
  "$font_root/JetBrainsMonoNerdFont-Italic.ttf"
  "$font_root/JetBrainsMonoNerdFont-BoldItalic.ttf"
  "$font_root/OFL.txt"
)
make_archive "$repo_dir/assets/jetbrains-mono-nerd-essential.tar.xz" "${font_paths[@]}"

printf '%s\n' "$active_theme" > "$repo_dir/state/theme"

validation_errors=0
reject_local_value() {
  local label="$1"
  local value="$2"
  [[ -n "$value" ]] || return 0
  matches=$(rg --hidden --files-with-matches --fixed-strings \
    --glob '!.git/**' --glob '!**/.git/**' --glob '!backup.sh' -- "$value" "$repo_dir" || true)
  if [[ -n "$matches" ]]; then
    printf 'Проверка остановлена (%s):\n%s\n' "$label" "$matches" >&2
    validation_errors=1
  fi
}

reject_local_value 'домашний путь' "/home/$(id -un)"
reject_local_value 'имя компьютера' "$(hostname)"

private_weather="${XDG_CONFIG_HOME:-$HOME/.config}/hyprpuccin/weather.json"
if [[ -r "$private_weather" ]]; then
  reject_local_value 'город для погоды' "$(jq -r '.city // empty' "$private_weather")"
  reject_local_value 'широта' "$(jq -r '.latitude // empty' "$private_weather")"
  reject_local_value 'долгота' "$(jq -r '.longitude // empty' "$private_weather")"
fi

secret_files=$(rg --hidden --files-with-matches --glob '!.git/**' --glob '!**/.git/**' \
  '(gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|AKIA[0-9A-Z]{16}|AIza[0-9A-Za-z_-]{30,}|BEGIN (RSA |OPENSSH |EC )?PRIVATE KEY)' \
  "$repo_dir" || true)
if [[ -n "$secret_files" ]]; then
  printf 'Проверка остановлена (похожая на ключ или токен строка):\n%s\n' "$secret_files" >&2
  validation_errors=1
fi

if command -v identify >/dev/null 2>&1; then
  for image_path in \
    "$repo_dir"/assets/wallpapers/* \
    "$repo_dir"/docs/screenshots/* \
    "$repo_dir"/docs/media/*.gif; do
    [[ -f "$image_path" ]] || continue
    if identify -verbose "$image_path" 2>/dev/null | rg -qi '(exif:GPS|GPSLatitude|GPSLongitude|GPSPosition)'; then
      printf 'Проверка остановлена (GPS-метаданные): %s\n' "$image_path" >&2
      validation_errors=1
    fi
  done
fi

(( validation_errors == 0 )) || {
  printf 'Сохранение отменено. Исправьте перечисленные файлы.\n' >&2
  exit 1
}

git -C "$repo_dir" add -A
if git -C "$repo_dir" diff --cached --quiet; then
  printf 'No configuration changes to commit.\n'
else
  TZ=UTC git -C "$repo_dir" commit -m "Update Hyprland configuration"
fi

if $push_changes && git -C "$repo_dir" remote get-url origin >/dev/null 2>&1; then
  git -C "$repo_dir" push
fi

printf 'Hyprland settings saved in %s\n' "$repo_dir"
