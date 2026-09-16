#!/usr/bin/env bash
# shellcheck shell=bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
DOTS=$ROOT/bin/dots
TMP=$(mktemp -d "${TMPDIR:-/tmp}/dots-test.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
pass=0

new_case() { R=$TMP/repo-$1; H=$TMP/home-$1; mkdir -p "$R" "$H"; printf '[defaults]\nstrategy = "symlink"\n' > "$R/dots.toml"; }
run() { DOTS_REPO=$R DOTS_HOME=$H "$DOTS" "$@"; }
ok() { "$@" || { printf 'FAIL: %s\n' "$*" >&2; exit 1; }; }
same_inode() { [[ $(stat -c '%d:%i' "$1" 2>/dev/null || stat -f '%d:%i' "$1") == $(stat -c '%d:%i' "$2" 2>/dev/null || stat -f '%d:%i' "$2") ]]; }
done_case() { pass=$((pass + 1)); }

new_case default; printf x > "$R/.bashrc"; run apply >/dev/null; ok test -L "$H/.bashrc"; ok test "$(readlink "$H/.bashrc")" = "$R/.bashrc"; run apply > "$TMP/out"; ok grep -q '0 created, 1 unchanged' "$TMP/out"; done_case

new_case nested; mkdir -p "$R/.config/app"; printf x > "$R/.config/app/config"; run apply >/dev/null; ok test -L "$H/.config/app/config"; done_case

new_case atomic; mkdir -p "$R/.config/nvim/lua"; printf x > "$R/.config/nvim/lua/init.lua"; printf '\n[".config/nvim"]\n' >> "$R/dots.toml"; run apply >/dev/null; ok test -L "$H/.config/nvim"; ok test ! -L "$H/.config/nvim/lua/init.lua"; done_case

new_case copy; printf source > "$R/file"; printf '\n["file"]\nstrategy = "copy"\n' >> "$R/dots.toml"; run apply >/dev/null; ok cmp -s "$R/file" "$H/file"; printf changed > "$H/file"; run status > "$TMP/out"; ok grep -q differs "$TMP/out"; run apply > "$TMP/out" || true; ok grep -q conflict "$TMP/out"; done_case

new_case copydir; mkdir -p "$R/tree/sub"; printf source > "$R/tree/sub/file"; printf '\n["tree"]\nstrategy = "copy"\n' >> "$R/dots.toml"; run apply >/dev/null; ok cmp -s "$R/tree/sub/file" "$H/tree/sub/file"; done_case

new_case hardlink; printf source > "$R/file"; printf '\n["file"]\nstrategy = "hardlink"\n' >> "$R/dots.toml"; run apply >/dev/null; ok same_inode "$R/file" "$H/file"; done_case

new_case hardlinkdir; mkdir -p "$R/tree"; printf '\n["tree"]\nstrategy = "hardlink"\n' >> "$R/dots.toml"; if run status >/dev/null 2>&1; then exit 1; fi; done_case

new_case target; mkdir -p "$R/shared"; printf source > "$R/shared/bashrc"; printf '\n["shared/bashrc"]\ntarget = ".bashrc"\n' >> "$R/dots.toml"; run apply >/dev/null; ok test -L "$H/.bashrc"; ok test ! -e "$H/shared/bashrc"; done_case

new_case conditions; printf l > "$R/linux"; printf d > "$R/darwin"; host=$(hostname -s 2>/dev/null || hostname); printf h > "$R/host"; printf '\n["linux"]\nos = ["linux"]\n\n["darwin"]\nos = ["darwin"]\n\n["host"]\nhosts = ["%s"]\n' "$host" >> "$R/dots.toml"; run apply >/dev/null; ok test -L "$H/host"; if [[ $(uname -s | tr A-Z a-z) == linux ]]; then ok test -L "$H/linux"; ok test ! -e "$H/darwin"; else ok test -L "$H/darwin"; ok test ! -e "$H/linux"; fi; done_case

new_case conflict; printf source > "$R/file"; printf user > "$H/file"; run apply > "$TMP/out" || true; ok grep -q conflict "$TMP/out"; ok grep -q user "$H/file"; done_case

new_case links; printf source > "$R/file"; ln -s /no/such/file "$H/file"; run status > "$TMP/out"; ok grep -q conflict "$TMP/out"; run apply --force >/dev/null; ok test "$(readlink "$H/file")" = "$R/file"; ln -s /wrong "$H/wrong"; printf x > "$R/wrong"; run status > "$TMP/out"; ok grep -q conflict "$TMP/out"; done_case

new_case internal; printf source > "$R/file"; ln -s file "$R/alias"; mkdir "$R/.git"; printf ignored > "$R/.git/secret"; run apply >/dev/null; ok test -L "$H/alias"; ok test ! -e "$H/.git/secret"; done_case

new_case traversal; printf source > "$R/file"; printf '\n["file"]\ntarget = "../outside"\n' >> "$R/dots.toml"; if run status >/dev/null 2>&1; then exit 1; fi; done_case

new_case duplicate; printf x > "$R/a"; printf y > "$R/b"; printf '\n["a"]\ntarget = "same"\n\n["b"]\ntarget = "same"\n' >> "$R/dots.toml"; if run status >/dev/null 2>&1; then exit 1; fi; done_case

new_case overlap; mkdir -p "$R/tree"; printf x > "$R/tree/file"; printf '\n["tree"]\n\n["tree/file"]\n' >> "$R/dots.toml"; if run status >/dev/null 2>&1; then exit 1; fi; done_case

new_case remove; printf x > "$R/file"; run apply >/dev/null; run remove file >/dev/null; ok test ! -e "$H/file"; printf user > "$H/file"; if run remove file >/dev/null 2>&1; then exit 1; fi; done_case

new_case ui; printf x > "$R/file"; NO_COLOR=1 run status > "$TMP/out"; ok test ! -s <(grep $'\033' "$TMP/out" || true); done_case

printf 'ok: %s isolated test cases\n' "$pass"
