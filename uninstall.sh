#!/usr/bin/env bash
# Remove only the executable selected by the same bin-directory rule as install.sh.
set -euo pipefail

init_ui() { if [[ -t 1 && -z ${NO_COLOR:-} ]]; then OK=$'\033[32m'; WARN=$'\033[33m'; ERR=$'\033[31m'; RESET=$'\033[0m'; else OK= WARN= ERR= RESET=; fi; }
die() { printf '%sdots: error:%s %s\n' "$ERR" "$RESET" "$*" >&2; exit 1; }
show_path() { if [[ $1 == "${HOME%/}/"* ]]; then printf '~/%s' "${1#"${HOME%/}/"}"; else printf '%s' "$1"; fi; }
usage() { cat <<'EOF'
Usage: ./uninstall.sh [--bin-dir <path>]

Remove dots from the selected directory (default: $HOME/.local/bin).
This script never changes PATH, shell startup files, or dotfiles.
EOF
}
expand_home() { case $1 in '~') printf '%s' "$HOME";; '~/'*) printf '%s/%s' "$HOME" "${1:2}";; *) printf '%s' "$1";; esac; }

init_ui
BIN_DIR=$HOME/.local/bin
while [[ $# -gt 0 ]]; do
  case $1 in
    --help|-h) usage; exit 0 ;;
    --bin-dir) [[ $# -ge 2 ]] || die '--bin-dir requires a path'; BIN_DIR=$2; shift 2 ;;
    *) die "unknown option: $1" ;;
  esac
done
BIN_DIR=$(expand_home "$BIN_DIR")
TARGET=$BIN_DIR/dots
if [[ ! -e $TARGET && ! -L $TARGET ]]; then
  printf 'dots is not installed in %s\n' "$(show_path "$BIN_DIR")"
  exit 0
fi
[[ ! -d $TARGET ]] || die "refusing to remove directory: $TARGET"
[[ ! -L $TARGET && -f $TARGET && -x $TARGET ]] || die "refusing to remove unexpected target type: $TARGET"
rm "$TARGET" || die "cannot remove $TARGET"
printf '%s✓%s Removed %s\n' "$OK" "$RESET" "$(show_path "$TARGET")"
