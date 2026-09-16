#!/usr/bin/env bash
# shellcheck shell=bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
DOTS=$ROOT/bin/dots
TMP=$(mktemp -d "${TMPDIR:-/tmp}/dots-test.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
pass=0

new_case() { R=$TMP/repo-$1; H=$TMP/home-$1; mkdir -p "$R" "$H"; printf '[defaults]\nstrategy = "symlink"\n' > "$R/dots.toml"; }
run() { (cd "$TMP"; DOTS_REPO=$R DOTS_HOME=$H "$DOTS" "$@"); }
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

# Discovery is tested from a neutral working directory so it cannot accidentally
# select this application's own repository.
DISC=$TMP/discovery; mkdir -p "$DISC/neutral" "$DISC/home" "$DISC/current" "$DISC/env" "$DISC/explicit" "$DISC/without-manifest"
printf '[defaults]\nstrategy = "symlink"\n' > "$DISC/current/dots.toml"; printf current > "$DISC/current/current-file"
printf '[defaults]\nstrategy = "symlink"\n' > "$DISC/env/dots.toml"; printf env > "$DISC/env/env-file"
printf '[defaults]\nstrategy = "symlink"\n' > "$DISC/explicit/dots.toml"; printf explicit > "$DISC/explicit/explicit-file"
mkdir -p "$DISC/home/.dotfiles"; printf '[defaults]\nstrategy = "symlink"\n' > "$DISC/home/.dotfiles/dots.toml"; printf fallback > "$DISC/home/.dotfiles/fallback-file"

(cd "$DISC/current"; HOME=$DISC/home DOTS_HOME=$DISC/home DOTS_REPO=$DISC/env "$DOTS" --repo "$DISC/explicit/." status > "$TMP/out")
ok grep -q "dots  $DISC/explicit" "$TMP/out"; ok grep -q explicit-file "$TMP/out"; ok test ! -e "$DISC/home/current-file"; done_case

(cd "$DISC/current"; HOME=$DISC/home DOTS_HOME=$DISC/home DOTS_REPO=$DISC/env "$DOTS" status > "$TMP/out")
ok grep -q "dots  $DISC/current" "$TMP/out"; ok grep -q current-file "$TMP/out"; ok test ! -e "$DISC/home/env-file"; done_case

(cd "$DISC/neutral"; HOME=$DISC/home DOTS_HOME=$DISC/home DOTS_REPO=$DISC/env "$DOTS" status > "$TMP/out")
ok grep -q "dots  $DISC/env" "$TMP/out"; ok grep -q env-file "$TMP/out"; done_case

(cd "$DISC/neutral"; HOME=$DISC/home DOTS_HOME=$DISC/home DOTS_REPO= "$DOTS" status > "$TMP/out")
ok grep -q "dots  ~/.dotfiles" "$TMP/out"; ok grep -q fallback-file "$TMP/out"; done_case

(cd "$DISC/neutral"; HOME=$DISC/home DOTS_HOME=$DISC/home DOTS_REPO= "$DOTS" --repo '~/.dotfiles' status > "$TMP/out")
ok grep -q "dots  ~/.dotfiles" "$TMP/out"; done_case

if (cd "$DISC/neutral"; HOME=$DISC/home DOTS_HOME=$DISC/home "$DOTS" --repo "$DISC/missing" status > "$TMP/out" 2>&1); then exit 1; fi
ok grep -q 'is not a dots repository (dots.toml not found)' "$TMP/out"; done_case

if (cd "$DISC/neutral"; HOME=$DISC/home DOTS_HOME=$DISC/home "$DOTS" --repo "$DISC/without-manifest" status > "$TMP/out" 2>&1); then exit 1; fi
ok grep -q "$DISC/without-manifest is not a dots repository" "$TMP/out"; done_case

SPACE="$DISC/repo with spaces"; mkdir -p "$SPACE"; printf '[defaults]\nstrategy = "symlink"\n' > "$SPACE/dots.toml"; printf spaced > "$SPACE/file"
(cd "$DISC/neutral"; HOME=$DISC/home DOTS_HOME=$DISC/home "$DOTS" status --repo "$SPACE/." > "$TMP/out")
ok grep -q "dots  $SPACE" "$TMP/out"; ok grep -q file "$TMP/out"; done_case

# Installation tests use an entirely separate HOME and never touch user files.
IH="$TMP/install home"; mkdir -p "$IH"; printf 'unchanged bashrc\n' > "$IH/.bashrc"; printf 'unchanged profile\n' > "$IH/.profile"
HOME="$IH" PATH=/usr/bin "$ROOT/install.sh" > "$TMP/out" 2> "$TMP/err"
ok test -x "$IH/.local/bin/dots"; ok test ! -L "$IH/.local/bin/dots"; ok "$IH/.local/bin/dots" --version >/dev/null; ok grep -q 'not in PATH' "$TMP/err"; ok grep -q 'unchanged bashrc' "$IH/.bashrc"; ok grep -q 'unchanged profile' "$IH/.profile"; done_case

printf '#!/usr/bin/env bash\necho old\n' > "$IH/.local/bin/dots"; chmod 755 "$IH/.local/bin/dots"
HOME="$IH" PATH="$IH/.local/bin:/usr/bin" "$ROOT/install.sh" > "$TMP/out" 2> "$TMP/err"
ok grep -q Updating "$TMP/out"; ok test ! -s "$TMP/err"; ok "$IH/.local/bin/dots" --version >/dev/null; done_case

CUSTOM="$TMP/custom bin with spaces"; HOME="$IH" PATH=/usr/bin "$ROOT/install.sh" --bin-dir "$CUSTOM" > "$TMP/out" 2> "$TMP/err"
ok test -x "$CUSTOM/dots"; ok "$CUSTOM/dots" --version >/dev/null; ok grep -q 'not in PATH' "$TMP/err"; done_case

HOME="$IH" PATH=/usr/bin "$ROOT/uninstall.sh" > "$TMP/out" 2> "$TMP/err"
ok test ! -e "$IH/.local/bin/dots"; ok test -d "$IH/.local/bin"; ok grep -q Removed "$TMP/out"; done_case

HOME="$IH" PATH=/usr/bin "$ROOT/uninstall.sh" --bin-dir "$CUSTOM" > "$TMP/out"
ok test ! -e "$CUSTOM/dots"; ok test -d "$CUSTOM"; done_case

HOME="$IH" PATH=/usr/bin "$ROOT/uninstall.sh" --bin-dir "$CUSTOM" > "$TMP/out"
ok grep -q 'not installed' "$TMP/out"; done_case

mkdir "$CUSTOM/dots"
if HOME="$IH" PATH=/usr/bin "$ROOT/uninstall.sh" --bin-dir "$CUSTOM" > "$TMP/out" 2>&1; then exit 1; fi
ok grep -q 'refusing to remove directory' "$TMP/out"; rmdir "$CUSTOM/dots"; done_case

HOME="$IH" PATH=/usr/bin NO_COLOR=1 "$ROOT/install.sh" --bin-dir "$CUSTOM" > "$TMP/out" 2> "$TMP/err"
if grep -q $'\033' "$TMP/out" "$TMP/err"; then exit 1; fi; done_case

HOME="$IH" PATH=/usr/bin "$ROOT/install.sh" --bin-dir "$CUSTOM" > "$TMP/out" 2> "$TMP/err"
if grep -q $'\033' "$TMP/out" "$TMP/err"; then exit 1; fi
ok grep -q 'unchanged bashrc' "$IH/.bashrc"; ok grep -q 'unchanged profile' "$IH/.profile"; done_case

printf 'ok: %s isolated test cases\n' "$pass"
