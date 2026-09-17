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

ok test -f "$ROOT/dots.toml.sample"; ok test ! -e "$ROOT/dots.toml"

new_case default; printf x > "$R/.bashrc"; run apply >/dev/null; ok test -L "$H/.bashrc"; ok test "$(readlink "$H/.bashrc")" = "$R/.bashrc"; run apply > "$TMP/out"; ok grep -q '0 created, 1 unchanged' "$TMP/out"; done_case

new_case selective; printf a > "$R/.bashrc"; mkdir -p "$R/.config/git"; printf b > "$R/.config/git/config"; run apply .bashrc > "$TMP/out"; ok test -L "$H/.bashrc"; ok test ! -e "$H/.config/git/config"; ok grep -q '.bashrc' "$TMP/out"; if grep -q '.config/git/config' "$TMP/out"; then exit 1; fi; run apply .config/git/config .bashrc .config/git/config > "$TMP/out"; ok test -L "$H/.config/git/config"; ok grep -q '1 created, 1 unchanged' "$TMP/out"; done_case

new_case selectiveforce; printf a > "$R/a"; printf b > "$R/b"; printf user-a > "$H/a"; printf user-b > "$H/b"; run apply --force a > "$TMP/out"; ok test -L "$H/a"; ok grep -q user-b "$H/b"; ok grep -q '1 created, 0 unchanged, 0 conflicts' "$TMP/out"; done_case

new_case selectivevalidate; printf a > "$R/a"; printf b > "$R/b"; if run apply a does-not-exist > "$TMP/out" 2>&1; then exit 1; fi; ok test ! -e "$H/a"; ok grep -q 'path is not managed' "$TMP/out"; if run apply ../outside > "$TMP/out" 2>&1; then exit 1; fi; ok test ! -e "$H/a"; done_case

new_case selectiveoverlay; mkdir -p "$R/_ser8/.config/hypr" "$R/_inactive"; printf base > "$R/.bashrc"; printf overlay > "$R/_ser8/.config/hypr/input.lua"; printf inactive > "$R/_inactive/file"; printf '\n[selectors]\nhost = "printf ser8"\n' >> "$R/dots.toml"; run apply .config/hypr/input.lua > "$TMP/out"; ok test "$(readlink "$H/.config/hypr/input.lua")" = "$R/_ser8/.config/hypr/input.lua"; if run apply _inactive/file > "$TMP/out" 2>&1; then exit 1; fi; ok grep -q 'path is not managed' "$TMP/out"; done_case

new_case selectiveatomic; mkdir -p "$R/.config/nvim"; printf init > "$R/.config/nvim/init.lua"; printf '\n[".config/nvim"]\n' >> "$R/dots.toml"; run apply .config/nvim > "$TMP/out"; ok test -L "$H/.config/nvim"; if run apply .config/nvim/init.lua > "$TMP/out" 2>&1; then exit 1; fi; ok grep -q "part of atomic directory '.config/nvim'" "$TMP/out"; done_case

new_case selectiveerror; printf a > "$R/a"; printf '\n[selectors]\nrole = "false"\n' >> "$R/dots.toml"; if run apply a > "$TMP/out" 2>&1; then exit 1; fi; ok test ! -e "$H/a"; done_case

new_case nested; mkdir -p "$R/.config/app"; printf x > "$R/.config/app/config"; run apply >/dev/null; ok test -L "$H/.config/app/config"; done_case

new_case gitignore; printf root > "$R/.gitignore"; mkdir -p "$R/.config/nvim" "$R/_ser8/.config/app"; printf nested > "$R/.config/nvim/.gitignore"; printf overlay > "$R/_ser8/.config/app/.gitignore"; printf '\n[selectors]\nhost = "printf ser8"\n' >> "$R/dots.toml"; run status > "$TMP/out"; if grep -q '^.*  .gitignore' "$TMP/out"; then exit 1; fi; ok grep -q '.config/nvim/.gitignore' "$TMP/out"; ok grep -q '.config/app/.gitignore' "$TMP/out"; run apply >/dev/null; ok test ! -e "$H/.gitignore"; ok test -L "$H/.config/nvim/.gitignore"; ok test -L "$H/.config/app/.gitignore"; if run apply .gitignore > "$TMP/out" 2>&1; then exit 1; fi; ok grep -q 'path is not managed' "$TMP/out"; done_case

new_case atomicgitignore; mkdir -p "$R/.config/nvim"; printf nested > "$R/.config/nvim/.gitignore"; printf '\n[".config/nvim"]\n' >> "$R/dots.toml"; run apply .config/nvim >/dev/null; ok test -L "$H/.config/nvim"; ok test -f "$H/.config/nvim/.gitignore"; done_case

new_case atomic; mkdir -p "$R/.config/nvim/lua"; printf x > "$R/.config/nvim/lua/init.lua"; printf '\n[".config/nvim"]\n' >> "$R/dots.toml"; run apply >/dev/null; ok test -L "$H/.config/nvim"; ok test ! -L "$H/.config/nvim/lua/init.lua"; done_case

new_case copy; printf source > "$R/file"; printf '\n["file"]\nstrategy = "copy"\n' >> "$R/dots.toml"; run apply >/dev/null; ok cmp -s "$R/file" "$H/file"; printf changed > "$H/file"; run status > "$TMP/out"; ok grep -q 'file conflict' "$TMP/out"; run apply > "$TMP/out" || true; ok grep -q 'file conflict' "$TMP/out"; done_case

new_case copydir; mkdir -p "$R/tree/sub"; printf source > "$R/tree/sub/file"; printf '\n["tree"]\nstrategy = "copy"\n' >> "$R/dots.toml"; run apply >/dev/null; ok cmp -s "$R/tree/sub/file" "$H/tree/sub/file"; done_case

new_case hardlink; printf source > "$R/file"; printf '\n["file"]\nstrategy = "hardlink"\n' >> "$R/dots.toml"; run apply >/dev/null; ok same_inode "$R/file" "$H/file"; done_case

new_case hardlinkdir; mkdir -p "$R/tree"; printf '\n["tree"]\nstrategy = "hardlink"\n' >> "$R/dots.toml"; if run status >/dev/null 2>&1; then exit 1; fi; done_case

new_case target; mkdir -p "$R/shared"; printf source > "$R/shared/bashrc"; printf '\n["shared/bashrc"]\ntarget = ".bashrc"\n' >> "$R/dots.toml"; run apply >/dev/null; ok test -L "$H/.bashrc"; ok test ! -e "$H/shared/bashrc"; done_case

new_case builtin; printf base > "$R/file"; if [[ $(uname -s) == Linux ]]; then mkdir -p "$R/_linux"; printf linux > "$R/_linux/file"; fi; run apply >/dev/null; ok test -L "$H/file"; if [[ $(uname -s) == Linux ]]; then ok test "$(readlink "$H/file")" = "$R/_linux/file"; fi; ok test -f "$ROOT/dots.toml.sample"; ok grep -q '^os = """' "$ROOT/dots.toml.sample"; ok grep -q 'Darwin) echo macos' "$ROOT/dots.toml.sample"; done_case

new_case overlay; printf base > "$R/.bashrc"; mkdir -p "$R/_linux" "$R/_omarchy" "$R/_ser8/.config/ghostty"; printf os > "$R/_linux/.bashrc"; printf distro > "$R/_omarchy/.bashrc"; printf host > "$R/_ser8/.bashrc"; printf overlay > "$R/_ser8/.config/ghostty/config"; printf '\n[selectors]\nos = "printf LINUX"\ndistro = "printf OMARCHY"\nhost = "printf SER8"\n' >> "$R/dots.toml"; run apply >/dev/null; ok test "$(readlink "$H/.bashrc")" = "$R/_ser8/.bashrc"; ok test "$(readlink "$H/.config/ghostty/config")" = "$R/_ser8/.config/ghostty/config"; ok test ! -e "$H/_linux"; run apply > "$TMP/out"; ok grep -q '0 created' "$TMP/out"; done_case

new_case sparse; mkdir -p "$R/.config" "$R/_laptop/.config"; printf base-a > "$R/.config/a"; printf base-b > "$R/.config/b"; printf over-a > "$R/_laptop/.config/a"; printf '\n[selectors]\nplatform = "printf LAPTOP"\n' >> "$R/dots.toml"; run apply >/dev/null; ok test "$(readlink "$H/.config/a")" = "$R/_laptop/.config/a"; ok test "$(readlink "$H/.config/b")" = "$R/.config/b"; done_case

new_case atomicoverlay; mkdir -p "$R/.config/nvim" "$R/_ser8/.config/nvim"; printf base > "$R/.config/nvim/init"; printf host > "$R/_ser8/.config/nvim/init"; printf '\n[selectors]\nhost = "printf ser8"\n\n[".config/nvim"]\n' >> "$R/dots.toml"; run apply >/dev/null; ok test "$(readlink "$H/.config/nvim")" = "$R/_ser8/.config/nvim"; done_case

new_case copyoverlay; printf base > "$R/file"; mkdir -p "$R/_workstation"; printf role > "$R/_workstation/file"; printf '\n[selectors]\nrole = "printf WorkStation"\n\n["file"]\nstrategy = "copy"\n' >> "$R/dots.toml"; run apply >/dev/null; ok grep -q role "$H/file"; done_case

new_case emptyselector; printf base > "$R/file"; mkdir -p "$R/_workstation"; printf over > "$R/_workstation/file"; printf '\n[selectors]\nrole = "true"\n' >> "$R/dots.toml"; run apply >/dev/null; ok test "$(readlink "$H/file")" = "$R/file"; done_case

new_case normalized; mkdir -p "$R/_macos" "$R/_fedora" "$R/_ser8"; printf mac > "$R/_macos/mac"; printf fedora > "$R/_fedora/distro"; printf host > "$R/_ser8/host"; printf '\n[selectors]\nos = "printf MACOS"\ndistro = "printf FEDORA"\nhost = "printf SER8"\n' >> "$R/dots.toml"; run apply >/dev/null; ok test "$(readlink "$H/mac")" = "$R/_macos/mac"; ok test "$(readlink "$H/distro")" = "$R/_fedora/distro"; ok test "$(readlink "$H/host")" = "$R/_ser8/host"; done_case

new_case distrofile; mkdir -p "$R/_alpine"; printf alpine > "$R/_alpine/file"; printf 'ID=ALPINE\n' > "$R/os-release"; printf '\n[selectors]\ndistro = """\n. "%s/os-release"\necho "$ID"\n"""\n' "$R" >> "$R/dots.toml"; run apply >/dev/null; ok test "$(readlink "$H/file")" = "$R/_alpine/file"; done_case

new_case selectorerror; printf base > "$R/file"; printf '\n[selectors]\nrole = "false"\n' >> "$R/dots.toml"; if run apply > "$TMP/out" 2>&1; then exit 1; fi; ok test ! -e "$H/file"; done_case

new_case selectorinvalid; printf base > "$R/file"; printf '\n[selectors]\nrole = "printf '\''Work Station'\''"\n' >> "$R/dots.toml"; if run status > "$TMP/out" 2>&1; then exit 1; fi; ok grep -q 'invalid value' "$TMP/out"; done_case

new_case selectortraversal; printf base > "$R/file"; printf '\n[selectors]\nrole = "printf '\''../../outside'\''"\n' >> "$R/dots.toml"; if run status > "$TMP/out" 2>&1; then exit 1; fi; ok grep -q 'invalid value' "$TMP/out"; done_case

new_case selectormultiline; printf base > "$R/file"; printf '\n[selectors]\nrole = "printf '\''one\\ntwo'\''"\n' >> "$R/dots.toml"; if run status > "$TMP/out" 2>&1; then exit 1; fi; ok grep -q 'multiple values' "$TMP/out"; done_case

new_case typeconflict; mkdir -p "$R/.config" "$R/_workstation"; printf base > "$R/.config/file"; printf over > "$R/_workstation/.config"; printf '\n[selectors]\nrole = "printf workstation"\n' >> "$R/dots.toml"; if run status > "$TMP/out" 2>&1; then exit 1; fi; ok grep -q 'type conflict' "$TMP/out"; done_case

new_case duplicatevalue; mkdir -p "$R/_linux"; printf x > "$R/_linux/file"; printf '\n[selectors]\nos = "printf linux"\nrole = "printf LINUX"\n' >> "$R/dots.toml"; if run apply > "$TMP/out" 2>&1; then exit 1; fi; ok grep -q 'both resolve' "$TMP/out"; ok test ! -e "$H/file"; done_case

new_case nestedunderscore; mkdir -p "$R/.config/app/_cache" "$R/_inactive"; printf nested > "$R/.config/app/_cache/file"; printf inactive > "$R/_inactive/file"; run apply >/dev/null; ok test -L "$H/.config/app/_cache/file"; ok test ! -e "$H/_inactive"; done_case

new_case missingoverlay; printf base > "$R/file"; printf '\n[selectors]\nrole = "printf workstation"\n' >> "$R/dots.toml"; run apply >/dev/null; ok test "$(readlink "$H/file")" = "$R/file"; done_case

new_case conflict; printf source > "$R/file"; printf user > "$H/file"; run apply > "$TMP/out" || true; ok grep -q conflict "$TMP/out"; ok grep -q user "$H/file"; done_case

new_case links; printf source > "$R/file"; ln -s /no/such/file "$H/file"; run status > "$TMP/out"; ok grep -q 'broken symlink' "$TMP/out"; ok test -L "$H/file"; run apply > "$TMP/out" || true; ok test -L "$H/file"; run apply --force >/dev/null; ok test "$(readlink "$H/file")" = "$R/file"; mkdir "$H/relative"; printf x > "$H/relative/file"; ln -s relative/file "$H/wrong-relative"; printf x > "$R/wrong-relative"; run status > "$TMP/out"; ok grep -q 'wrong symlink' "$TMP/out"; printf x > "$TMP/absolute-source"; ln -s "$TMP/absolute-source" "$H/wrong-absolute"; printf x > "$R/wrong-absolute"; run status > "$TMP/out"; ok grep -q 'wrong symlink' "$TMP/out"; done_case

new_case conflicttypes; printf source > "$R/file"; printf source > "$R/dir"; printf source > "$R/pipe"; printf user > "$H/file"; mkdir "$H/dir"; mkfifo "$H/pipe"; run status > "$TMP/out"; ok grep -q 'file  file conflict' "$TMP/out"; ok grep -q 'dir  directory conflict' "$TMP/out"; ok grep -q 'pipe  other conflict' "$TMP/out"; run apply > "$TMP/out" || true; ok test -f "$H/file"; ok test -d "$H/dir"; ok test -p "$H/pipe"; ok grep -q '3 conflicts' "$TMP/out"; run apply --force >/dev/null; ok test -L "$H/file"; ok test -L "$H/dir"; ok test -L "$H/pipe"; done_case

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
