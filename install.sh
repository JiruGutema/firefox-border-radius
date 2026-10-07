#!/usr/bin/env bash
#
# firefox-border-radius: set one corner radius for (almost) everything in Firefox.
#
# Finds every Firefox install on the machine (apt/rpm/pacman/tarball, Snap,
# Flatpak, and Firefox-based browsers like LibreWolf), lists all of their
# profiles, and lets you choose which ones to apply it to. Each selected
# profile gets a clean chrome/ folder containing just userChrome.css and
# userContent.css; whatever was in chrome/ before is moved to a backup.
#
# Kept bash 3.2 compatible so it runs on stock macOS (which is also why there
# is no `set -u`: bash 3.2 treats "${empty_array[@]}" as unbound).

set -eo pipefail

NAME="firefox-border-radius"
MARKER="/* Installed by $NAME. Re-run install.sh to change it; edits to this file are overwritten. */"
PREF_NAME="toolkit.legacyUserProfileCustomizations.stylesheets"
PREF_LINE="user_pref(\"$PREF_NAME\", true); // $NAME"
BACKUP_ROOT="${XDG_DATA_HOME:-$HOME/.local/share}/$NAME/backups"
STAMP="$(date +%Y%m%d-%H%M%S)"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$SCRIPT_DIR/src"

radius="4px"
mode="install"
with_content=1
select_all=0
assume_yes=0
profile_args=()

if [ -t 1 ]; then
  bold=$'\033[1m'; dim=$'\033[2m'; red=$'\033[31m'; green=$'\033[32m'; yellow=$'\033[33m'; cyan=$'\033[36m'; reset=$'\033[0m'
else
  bold=""; dim=""; red=""; green=""; yellow=""; cyan=""; reset=""
fi

info() { printf '%s\n' "$*"; }
ok()   { printf '%s✓%s %s\n' "$green" "$reset" "$*"; }
warn() { printf '%s!%s %s\n' "$yellow" "$reset" "$*" >&2; }
die()  { printf '%serror:%s %s\n' "$red" "$reset" "$*" >&2; exit 1; }
tilde() { case "$1" in "$HOME"/*) printf '~%s' "${1#"$HOME"}" ;; *) printf '%s' "$1" ;; esac; }

usage() {
  cat <<EOF
Usage: ./install.sh [options]

Set the border radius of Firefox's tabs, toolbar, URL bar, menus, panels and
about: pages to a single value. Without options it lists every Firefox
profile it can find and asks which ones to apply it to.

Options:
  -r, --radius VALUE   Corner radius, e.g. 0, 4, 8px (default: 4px)
  -a, --all            Apply to every profile found, without the menu
  -p, --profile DIR    Apply to this profile directory (repeatable, skips the menu)
  -l, --list           List Firefox installs and profiles, then exit
  -u, --uninstall      Remove $NAME from the profiles you choose
      --no-content     Leave about: pages alone (don't install userContent.css)
  -y, --yes            Don't ask for confirmation
  -h, --help           Show this help

Examples:
  ./install.sh                  # pick profiles from a list, 4px
  ./install.sh -r 0             # sharp corners
  ./install.sh -a -r 8 -y       # every profile, no questions
  ./install.sh --uninstall
EOF
}

# ---------------------------------------------------------------- arguments --

while [ $# -gt 0 ]; do
  case "$1" in
    -r|--radius)    [ $# -ge 2 ] || die "$1 needs a value"; radius="$2"; shift 2 ;;
    --radius=*)     radius="${1#*=}"; shift ;;
    -a|--all)       select_all=1; shift ;;
    -p|--profile)   [ $# -ge 2 ] || die "$1 needs a directory"; profile_args+=("$2"); shift 2 ;;
    --profile=*)    profile_args+=("${1#*=}"); shift ;;
    -l|--list)      mode="list"; shift ;;
    -u|--uninstall) mode="uninstall"; shift ;;
    --no-content)   with_content=0; shift ;;
    -y|--yes)       assume_yes=1; shift ;;
    -h|--help)      usage; exit 0 ;;
    *)              usage >&2; die "unknown option: $1" ;;
  esac
done

case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) die "on Windows, run install.ps1 instead (see README)" ;;
esac

if [ "$mode" = "install" ]; then
  r="${radius%px}"
  printf '%s' "$r" | grep -Eq '^[0-9]+(\.[0-9]+)?$' \
    || die "invalid radius '$radius' (use a number like 4 or 4px)"
  radius="${r}px"

  for f in userChrome.css userContent.css; do
    [ -f "$SRC_DIR/$f" ] || die "missing $SRC_DIR/$f (run install.sh from a full checkout of the repo)"
  done
fi

# ---------------------------------------------------------- install detection --

# How the native (non-sandboxed) Firefox was installed, e.g. "apt". Fails if
# there is no native Firefox.
native_kind() {
  local bin path real
  for bin in firefox firefox-esr firefox-developer-edition firefox-nightly; do
    path="$(command -v "$bin" 2>/dev/null)" || continue
    real="$(readlink -f "$path" 2>/dev/null || printf '%s' "$path")"
    case "$real" in /snap/*|*/flatpak/*) continue ;; esac
    # Ubuntu's "firefox" deb is only a wrapper that launches the Snap.
    if [ "$(head -c 2 "$real" 2>/dev/null)" = "#!" ] && grep -q '/snap/bin/firefox' "$real" 2>/dev/null; then
      continue
    fi
    case "$real" in /nix/*) echo "nix"; return 0 ;; esac
    if command -v dpkg-query >/dev/null 2>&1 && dpkg-query -S "$real" >/dev/null 2>&1; then echo "apt"
    elif command -v rpm >/dev/null 2>&1 && rpm -qf "$real" >/dev/null 2>&1; then echo "rpm"
    elif command -v pacman >/dev/null 2>&1 && pacman -Qqo "$real" >/dev/null 2>&1; then echo "pacman"
    else echo "tarball"
    fi
    return 0
  done
  return 1
}

snap_has()    { [ -e "/snap/bin/$1" ] || { command -v snap >/dev/null 2>&1 && snap list "$1" >/dev/null 2>&1; }; }
flatpak_has() { command -v flatpak >/dev/null 2>&1 && flatpak info "$1" >/dev/null 2>&1; }
cmd_has()     { command -v "$1" >/dev/null 2>&1; }

# Installs, one per line: label <TAB> installed(1/0) <TAB> profile root.
# A browser can have more than one root (newer Firefox uses ~/.config).
INSTALLS=()
add_install() { INSTALLS+=("$1	$2	$3"); }

detect_installs() {
  local nk native=0 snap=0 flat=0 x
  case "$(uname -s)" in
    Darwin)
      [ -d /Applications/Firefox.app ] && x=1 || x=0
      add_install "Firefox (macOS)" "$x" "$HOME/Library/Application Support/Firefox"
      [ -d /Applications/LibreWolf.app ] && x=1 || x=0
      add_install "LibreWolf (macOS)" "$x" "$HOME/Library/Application Support/librewolf"
      [ -d /Applications/Floorp.app ] && x=1 || x=0
      add_install "Floorp (macOS)" "$x" "$HOME/Library/Application Support/Floorp"
      [ -d "/Applications/Zen.app" ] && x=1 || x=0
      add_install "Zen (macOS)" "$x" "$HOME/Library/Application Support/zen"
      return 0
      ;;
  esac

  if nk="$(native_kind)"; then native=1; else nk="native"; fi
  snap_has firefox && snap=1
  flatpak_has org.mozilla.firefox && flat=1

  add_install "Firefox ($nk)" "$native" "$HOME/.mozilla/firefox"
  add_install "Firefox ($nk)" "$native" "${XDG_CONFIG_HOME:-$HOME/.config}/mozilla/firefox"
  add_install "Firefox (snap)" "$snap" "$HOME/snap/firefox/common/.mozilla/firefox"
  add_install "Firefox (flatpak)" "$flat" "$HOME/.var/app/org.mozilla.firefox/.mozilla/firefox"
  add_install "Firefox (flatpak)" "$flat" "$HOME/.var/app/org.mozilla.firefox/config/mozilla/firefox"

  # Firefox-based browsers use the same profile layout and userChrome.css.
  cmd_has librewolf && x=1 || x=0
  add_install "LibreWolf" "$x" "$HOME/.librewolf"
  flatpak_has io.gitlab.librewolf-community && x=1 || x=0
  add_install "LibreWolf (flatpak)" "$x" "$HOME/.var/app/io.gitlab.librewolf-community/.librewolf"
  cmd_has floorp && x=1 || x=0
  add_install "Floorp" "$x" "$HOME/.floorp"
  flatpak_has one.ablaze.floorp && x=1 || x=0
  add_install "Floorp (flatpak)" "$x" "$HOME/.var/app/one.ablaze.floorp/.floorp"
  { cmd_has zen-browser || cmd_has zen; } && x=1 || x=0
  add_install "Zen" "$x" "$HOME/.zen"
  flatpak_has app.zen_browser.zen && x=1 || x=0
  add_install "Zen (flatpak)" "$x" "$HOME/.var/app/app.zen_browser.zen/.zen"
  { cmd_has waterfox || snap_has waterfox; } && x=1 || x=0
  add_install "Waterfox" "$x" "$HOME/.waterfox"
}

# ---------------------------------------------------------- profile detection --

# Profiles in <root>/profiles.ini as: name <TAB> absolute path <TAB> default(1/0).
profiles_from_ini() {
  local root="$1"
  [ -f "$root/profiles.ini" ] || return 0
  awk -F= -v root="$root" '
    { sub(/\r$/, "") }
    /^\[/ { sec = $0; next }
    sec ~ /^\[Profile[0-9]+\]$/ {
      if (!(sec in seen)) { seen[sec] = 1; order[++n] = sec; rel[sec] = "1" }
      if ($1 == "Name")       name[sec] = substr($0, 6)
      if ($1 == "Path")       path[sec] = substr($0, 6)
      if ($1 == "IsRelative") rel[sec]  = $2
      if ($1 == "Default" && $2 == "1") legacy_default[sec] = 1
    }
    sec ~ /^\[Install/ && $1 == "Default" { installs = 1; install_default[substr($0, 9)] = 1 }
    END {
      for (i = 1; i <= n; i++) {
        s = order[i]
        if (path[s] == "") continue
        p = (rel[s] == "0") ? path[s] : root "/" path[s]
        d = installs ? (path[s] in install_default) : (s in legacy_default)
        print name[s] "\t" p "\t" (d ? 1 : 0)
      }
    }
  ' "$root/profiles.ini"
}

# Profiles that aren't in profiles.ini (e.g. newer Firefox profile groups):
# any directory that has a prefs.js.
profiles_from_scan() {
  local root="$1" d base
  for d in "$root"/*/ "$root"/Profiles/*/; do
    [ -f "$d/prefs.js" ] || continue
    d="${d%/}"; base="${d##*/}"
    printf '%s\t%s\t0\n' "${base#*.}" "$d"
  done
  return 0
}

# Discovered profiles, as parallel arrays.
P_LABEL=(); P_NAME=(); P_PATH=(); P_DEFAULT=()

add_profile() {
  local label="$1" name="$2" path="$3" def="$4" i
  [ -d "$path" ] || return 0
  path="$(cd "$path" && pwd -P)"
  for i in "${!P_PATH[@]}"; do
    [ "${P_PATH[$i]}" = "$path" ] && return 0
  done
  P_LABEL+=("$label"); P_NAME+=("$name"); P_PATH+=("$path"); P_DEFAULT+=("$def")
}

detect_profiles() {
  local entry label installed root name path def
  for entry in "${INSTALLS[@]}"; do
    IFS=$'\t' read -r label installed root <<<"$entry"
    [ -d "$root" ] || continue
    while IFS=$'\t' read -r name path def; do
      add_profile "$label" "$name" "$path" "$def"
    done < <(profiles_from_ini "$root"; profiles_from_scan "$root")
  done
}

is_ours()      { [ -f "$1" ] && [ "$(head -n 1 "$1")" = "$MARKER" ]; }
is_installed() { is_ours "$1/chrome/userChrome.css"; }
# Linux: while running, Firefox keeps <profile>/lock -> "<ip>:+<pid>". A crash
# can leave it behind, so also check that the process is still alive.
in_use() {
  local target
  target="$(readlink "$1/lock" 2>/dev/null)" || return 1
  kill -0 "${target##*+}" 2>/dev/null
}

# Is chrome/ empty or only holding files we wrote?
chrome_is_clean() {
  local chrome="$1/chrome" f
  [ -d "$chrome" ] || return 0
  for f in "$chrome"/* "$chrome"/.[!.]*; do
    [ -e "$f" ] || continue
    case "${f##*/}" in
      userChrome.css|userContent.css) is_ours "$f" || return 1 ;;
      *) return 1 ;;
    esac
  done
  return 0
}

profile_notes() {
  local p="$1" i="$2" notes=""
  [ "${P_DEFAULT[$i]}" = "1" ] && notes="default"
  in_use "$p" && notes="${notes:+$notes, }in use"
  if is_installed "$p"; then
    notes="${notes:+$notes, }${green}installed${reset}"
  elif ! chrome_is_clean "$p"; then
    notes="${notes:+$notes, }${yellow}has other chrome/ files${reset}"
  fi
  printf '%s' "$notes"
}

label_has_root() {
  local entry label installed root
  for entry in "${INSTALLS[@]}"; do
    IFS=$'\t' read -r label installed root <<<"$entry"
    [ "$label" = "$1" ] && [ -d "$root" ] && return 0
  done
  return 1
}

print_installs() {
  local entry label installed root count i note
  info "${bold}Firefox installs${reset}"
  for entry in "${INSTALLS[@]}"; do
    IFS=$'\t' read -r label installed root <<<"$entry"
    if [ -d "$root" ]; then
      count=0
      for i in "${!P_PATH[@]}"; do
        case "${P_PATH[$i]}" in "$root"/*) count=$((count + 1)) ;; esac
      done
      note="$count profile$([ "$count" = 1 ] || echo s)"
      [ "$installed" = 1 ] || note="$note, app not found"
    elif [ "$installed" = 1 ] && ! label_has_root "$label"; then
      note="no profiles yet, start it once"
    else
      continue
    fi
    printf '  %-22s %s  %s(%s)%s\n' "$label" "$(tilde "$root")" "$dim" "$note" "$reset"
  done
  echo
}

print_profiles() {
  local i notes
  info "${bold}Profiles${reset}"
  for i in "${!P_PATH[@]}"; do
    notes="$(profile_notes "${P_PATH[$i]}" "$i")"
    printf '  %s%2d)%s %-20s %s%-20s%s %s\n' "$cyan" $((i + 1)) "$reset" "${P_NAME[$i]}" "$dim" "${P_LABEL[$i]}" "$reset" "$notes"
    printf '       %s%s%s\n' "$dim" "$(tilde "${P_PATH[$i]}")" "$reset"
  done
  echo
}

# ------------------------------------------------------------------ selection --

SELECTED=()   # indexes into P_*

open_tty() {
  # Works even when the script itself is piped into bash.
  { exec 3</dev/tty; } 2>/dev/null
}

select_add() {
  local n="$1" s
  for s in ${SELECTED[@]+"${SELECTED[@]}"}; do [ "$s" = "$n" ] && return 0; done
  SELECTED+=("$n")
}

prompt_selection() {
  local total="${#P_PATH[@]}" answer tok a b n
  while :; do
    printf '%sSelect profiles%s (e.g. 1 3, 2-4, a = all, q = quit) [a]: ' "$bold" "$reset"
    read -r answer <&3 || answer="q"
    SELECTED=()
    case "$answer" in
      ""|a|A|all) for n in "${!P_PATH[@]}"; do SELECTED+=("$n"); done; return 0 ;;
      q|Q|quit)   info "Nothing changed."; exit 0 ;;
    esac
    local valid=1
    for tok in $(printf '%s' "$answer" | tr ',' ' '); do
      case "$tok" in
        *-*)
          a="${tok%-*}"; b="${tok#*-}"
          if printf '%s%s' "$a" "$b" | grep -Eq '^[0-9]+$' && [ "$a" -ge 1 ] && [ "$b" -le "$total" ] && [ "$a" -le "$b" ]; then
            n="$a"; while [ "$n" -le "$b" ]; do select_add $((n - 1)); n=$((n + 1)); done
          else valid=0; fi ;;
        *)
          if printf '%s' "$tok" | grep -Eq '^[0-9]+$' && [ "$tok" -ge 1 ] && [ "$tok" -le "$total" ]; then
            select_add $((tok - 1))
          else valid=0; fi ;;
      esac
    done
    if [ "$valid" = 1 ] && [ ${#SELECTED[@]} -gt 0 ]; then return 0; fi
    warn "Enter numbers between 1 and $total, ranges like 2-4, or a for all."
  done
}

confirm() {
  [ "$assume_yes" = 1 ] && return 0
  open_tty || return 0
  local answer
  printf '%s [Y/n] ' "$1"
  read -r answer <&3 || answer=""
  case "$answer" in [nN]*) info "Nothing changed."; exit 1 ;; esac
}

# ------------------------------------------------------------- applying files --

backup_dir_for() {
  printf '%s/%s-%s' "$BACKUP_ROOT" "${1##*/}" "$STAMP"
}

render() {
  printf '%s\n' "$MARKER"
  sed "s/@RADIUS@/$radius/g" "$SRC_DIR/$1"
}

# userChrome/userContent are ignored unless this pref is true. user.js is
# applied on every start, so this survives Firefox resetting prefs.
enable_pref() {
  local p="$1" userjs="$1/user.js" tmp
  if [ -f "$userjs" ] && grep -Eq "^[[:space:]]*user_pref\(\"$PREF_NAME\",[[:space:]]*true\)" "$userjs"; then
    return 0
  fi
  if [ -f "$userjs" ]; then
    mkdir -p "$(backup_dir_for "$p")"
    cp -p "$userjs" "$(backup_dir_for "$p")/user.js"
  fi
  tmp="$(mktemp "$userjs.XXXXXX")"
  { [ -f "$userjs" ] && grep -vF "\"$PREF_NAME\"" "$userjs"; printf '%s\n' "$PREF_LINE"; } > "$tmp" || true
  mv "$tmp" "$userjs"
}

disable_pref() {
  local userjs="$1/user.js" tmp
  [ -f "$userjs" ] && grep -qF "$PREF_LINE" "$userjs" || return 0
  tmp="$(mktemp "$userjs.XXXXXX")"
  grep -vF "$PREF_LINE" "$userjs" > "$tmp" || true
  if grep -q '[^[:space:]]' "$tmp"; then mv "$tmp" "$userjs"; else rm -f "$tmp" "$userjs"; fi
}

install_profile() {
  local p="$1" chrome="$1/chrome" backup
  if ! chrome_is_clean "$p"; then
    backup="$(backup_dir_for "$p")"
    mkdir -p "$backup"
    mv "$chrome" "$backup/chrome"
    info "    old chrome/ moved to $(tilde "$backup")/chrome"
  fi
  mkdir -p "$chrome"
  render userChrome.css > "$chrome/userChrome.css"
  if [ "$with_content" = 1 ]; then
    render userContent.css > "$chrome/userContent.css"
  else
    rm -f "$chrome/userContent.css"
  fi
  enable_pref "$p"
}

uninstall_profile() {
  local p="$1" f latest
  for f in userChrome.css userContent.css; do
    is_ours "$p/chrome/$f" && rm -f "$p/chrome/$f"
  done
  rmdir "$p/chrome" 2>/dev/null || true
  disable_pref "$p"
  latest="$(ls -d "$BACKUP_ROOT/${p##*/}-"*/chrome 2>/dev/null | tail -n 1 || true)"
  if [ -n "$latest" ]; then
    info "    your previous chrome/ is saved at $(tilde "$latest")"
  fi
}

# ----------------------------------------------------------------------- main --

detect_installs
detect_profiles

if [ "$mode" = "list" ]; then
  print_installs
  if [ ${#P_PATH[@]} -gt 0 ]; then print_profiles; else info "No profiles found."; fi
  exit 0
fi

if [ ${#profile_args[@]} -gt 0 ]; then
  for arg in "${profile_args[@]}"; do
    dir="${arg/#\~/$HOME}"
    [ -d "$dir" ] || die "profile directory not found: $arg"
    dir="$(cd "$dir" && pwd -P)"
    add_profile "custom" "${dir##*/}" "$dir" 0
    for i in "${!P_PATH[@]}"; do [ "${P_PATH[$i]}" = "$dir" ] && select_add "$i"; done
  done
else
  [ ${#P_PATH[@]} -gt 0 ] \
    || die "no Firefox profiles found. Start Firefox once, or pass --profile DIR (see about:support → Profile Folder)."
  print_installs
  print_profiles
  if [ "$select_all" = 1 ]; then
    for i in "${!P_PATH[@]}"; do SELECTED+=("$i"); done
  elif open_tty; then
    prompt_selection
  else
    die "no terminal to ask which profiles to use; pass --all or --profile DIR."
  fi
fi

echo
if [ "$mode" = "install" ]; then
  info "Applying radius ${bold}$radius${reset} to ${#SELECTED[@]} profile(s):"
else
  info "Removing $NAME from ${#SELECTED[@]} profile(s):"
fi
needs_backup=0
for i in "${SELECTED[@]}"; do
  info "  ${P_NAME[$i]} ${dim}(${P_LABEL[$i]})${reset}"
  chrome_is_clean "${P_PATH[$i]}" || needs_backup=1
done
if [ "$mode" = "install" ] && [ "$needs_backup" = 1 ]; then
  warn "Existing chrome/ folders will be replaced. Their contents are moved to $(tilde "$BACKUP_ROOT")."
fi
confirm "Continue?"
echo

restart=""
for i in "${SELECTED[@]}"; do
  p="${P_PATH[$i]}"
  if [ "$mode" = "install" ]; then install_profile "$p"; else uninstall_profile "$p"; fi
  ok "${P_NAME[$i]} ${dim}($(tilde "$p"))${reset}"
  case "$restart" in *"|${P_LABEL[$i]}|"*) ;; *) restart="$restart|${P_LABEL[$i]}|" ;; esac
done

echo
restart="$(printf '%s' "$restart" | tr -s '|' '\n' | sed '/^$/d' | paste -sd ',' - | sed 's/,/, /g')"
info "Done. Quit and restart: ${bold}$restart${reset}"
