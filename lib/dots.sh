#!/usr/bin/env bash
# shellcheck shell=bash

DOTS_VERSION=0.1.0

die() { printf 'dots: error: %s\n' "$*" >&2; exit 1; }
warn() { printf 'dots: warning: %s\n' "$*" >&2; }

init_ui() {
  if [[ -t 1 && -z ${NO_COLOR:-} ]]; then
    C_OK=$'\033[32m'; C_ADD=$'\033[36m'; C_WARN=$'\033[33m'; C_ERR=$'\033[31m'; C_DIM=$'\033[2m'; C_BOLD=$'\033[1m'; C_RESET=$'\033[0m'
  else
    C_OK= C_ADD= C_WARN= C_ERR= C_DIM= C_BOLD= C_RESET=
  fi
}
mark() { local color=$1 symbol=$2; printf '%s%s%s' "$color" "$symbol" "$C_RESET"; }

usage() {
  cat <<'EOF'
Usage: dots [--help] [--version] <command>

Commands:
  status          Show the derived deployment state (read-only).
  apply [--force] Create missing deployments; --force replaces conflicts.
  remove <path>   Remove a deployment only when it still matches its source.

Repository discovery: set DOTS_REPO to the repository root, or run from a
directory below a repository containing dots.toml. DOTS_HOME overrides HOME,
primarily for testing.
EOF
}

valid_relpath() {
  local p=$1
  [[ -n $p && $p != /* && $p != */ && $p != *'//' && $p != . && $p != .. && $p != ../* && $p != */../* && $p != */.. && $p != *$'\n'* ]]
}

find_repo() {
  local d
  if [[ -n ${DOTS_REPO:-} ]]; then
    [[ -d $DOTS_REPO && -f $DOTS_REPO/dots.toml ]] || die "DOTS_REPO must name a directory containing dots.toml"
    REPO=$(cd "$DOTS_REPO" && pwd -P)
    return
  fi
  d=$(pwd -P)
  while :; do
    if [[ -f $d/dots.toml ]]; then REPO=$d; return; fi
    [[ $d == / ]] && break
    d=${d%/*}; [[ -n $d ]] || d=/
  done
  die "repository not found; set DOTS_REPO or run below a directory containing dots.toml"
}

trim() { local x=$1; x=${x#"${x%%[![:space:]]*}"}; x=${x%"${x##*[![:space:]]}"}; printf '%s' "$x"; }
unquote() {
  local v
  v=$(trim "$1")
  [[ $v == \"*\" && ${#v} -ge 2 ]] || return 1
  v=${v:1:${#v}-2}
  [[ $v != *'"'* && $v != *'\\'* ]] || return 1
  printf '%s' "$v"
}
parse_string_array() {
  local v item rest out=()
  v=$(trim "$1"); [[ $v == \[*\] ]] || return 1
  rest=$(trim "${v:1:${#v}-2}")
  [[ -z $rest ]] && { printf ''; return; }
  while [[ -n $rest ]]; do
    [[ $rest == \"* ]] || return 1
    item=${rest#\"}; item=${item%%\"*}
    [[ -n $item && $item != *\\* ]] || return 1
    rest=${rest#\"$item\"}; out+=("$item")
    rest=$(trim "$rest")
    [[ -z $rest ]] && break
    [[ $rest == ,* ]] || return 1
    rest=$(trim "${rest:1}")
  done
  (IFS=$'\034'; printf '%s' "${out[*]}")
}

declare -a CFG_SOURCE=() CFG_TARGET=() CFG_STRATEGY=() CFG_OS=() CFG_HOSTS=() CFG_KEYS=()
cfg_index_for() {
  local sought=$1 j
  for j in "${!CFG_SOURCE[@]}"; do [[ ${CFG_SOURCE[j]} == "$sought" ]] && { CFG_LOOKUP=$j; return 0; }; done
  return 1
}
parse_manifest() {
  local file=$REPO/dots.toml line n=0 section= key value source i defaults_keys=
  DEFAULT_STRATEGY=symlink
  [[ -f $file ]] || die "dots.toml is required for repository discovery and metadata"
  while IFS= read -r line || [[ -n $line ]]; do
    ((++n))
    line=${line%%#*}; line=$(trim "$line"); [[ -z $line ]] && continue
    if [[ $line =~ ^\[defaults\]$ ]]; then section=defaults; continue; fi
    if [[ $line =~ ^\[\"([^\"]+)\"\]$ ]]; then
      source=${BASH_REMATCH[1]}; valid_relpath "$source" || die "dots.toml:$n: unsafe source path"
      if cfg_index_for "$source"; then die "dots.toml:$n: duplicate table '$source'"; fi
      i=${#CFG_SOURCE[@]}; CFG_SOURCE+=("$source"); CFG_TARGET+=("$source"); CFG_STRATEGY+=(""); CFG_OS+=(""); CFG_HOSTS+=(""); CFG_KEYS+=("|"); section=$source; continue
    fi
    [[ $line =~ ^([a-z]+)[[:space:]]*=[[:space:]]*(.*)$ ]] || die "dots.toml:$n: unsupported syntax"
    key=${BASH_REMATCH[1]}; value=${BASH_REMATCH[2]}
    if [[ $section == defaults ]]; then
      [[ $key == strategy ]] || die "dots.toml:$n: only defaults.strategy is supported"
      [[ $defaults_keys != *"|$key|"* ]] || die "dots.toml:$n: duplicate key '$key'"
      defaults_keys="${defaults_keys}|$key|"
      DEFAULT_STRATEGY=$(unquote "$value") || die "dots.toml:$n: expected a simple quoted string"
      continue
    fi
    [[ -n $section ]] || die "dots.toml:$n: key outside a table"
    cfg_index_for "$section" || die "dots.toml:$n: internal table lookup failure"
    i=$CFG_LOOKUP
    [[ ${CFG_KEYS[i]} != *"|$key|"* ]] || die "dots.toml:$n: duplicate key '$key'"
    CFG_KEYS[i]="${CFG_KEYS[i]}$key|"
    case $key in
      target) CFG_TARGET[i]=$(unquote "$value") || die "dots.toml:$n: expected a simple quoted string"; valid_relpath "${CFG_TARGET[i]}" || die "dots.toml:$n: unsafe target path" ;;
      strategy) CFG_STRATEGY[i]=$(unquote "$value") || die "dots.toml:$n: expected a simple quoted string" ;;
      os) CFG_OS[i]=$(parse_string_array "$value") || die "dots.toml:$n: expected an array of simple quoted strings" ;;
      hosts) CFG_HOSTS[i]=$(parse_string_array "$value") || die "dots.toml:$n: expected an array of simple quoted strings" ;;
      *) die "dots.toml:$n: unsupported key '$key'" ;;
    esac
  done < "$file"
  case $DEFAULT_STRATEGY in symlink|hardlink|copy) ;; *) die "invalid defaults.strategy '$DEFAULT_STRATEGY'";; esac
}

list_has() { local needle=$1 list=$2 x; IFS=$'\034' read -r -a _list <<< "$list"; for x in "${_list[@]}"; do [[ $x == "$needle" ]] && return 0; done; return 1; }
entry_enabled() {
  local i=$1
  [[ -z ${CFG_OS[i]} ]] || list_has "$CURRENT_OS" "${CFG_OS[i]}" || return 1
  [[ -z ${CFG_HOSTS[i]} ]] || list_has "$CURRENT_HOST" "${CFG_HOSTS[i]}" || return 1
}

declare -a ESOURCE=() ETARGET=() ESTRATEGY=() ETYPE=()
add_entry() {
  local s=$1 t=$2 st=$3 ty=$4 existing
  valid_relpath "$s" || die "unsafe source path '$s'"; valid_relpath "$t" || die "unsafe target path '$t'"
  case $st in symlink|hardlink|copy) ;; *) die "invalid strategy '$st' for '$s'";; esac
  [[ -e $REPO/$s || -L $REPO/$s ]] || die "source does not exist: $s"
  [[ $st != hardlink || $ty == file ]] || die "cannot hardlink directory '$s'"
  for existing in "${ETARGET[@]}"; do [[ $existing != "$t" ]] || die "conflicting target definitions for '$t'"; done
  ESOURCE+=("$s"); ETARGET+=("$t"); ESTRATEGY+=("$st"); ETYPE+=("$ty")
}
under_explicit() { local p=$1 x; for x in "${CFG_SOURCE[@]}"; do [[ $p == "$x" || $p == "$x/"* ]] && return 0; done; return 1; }
build_desired() {
  local i s t st p ty
  CURRENT_OS=$(uname -s | tr '[:upper:]' '[:lower:]'); CURRENT_HOST=$(hostname -s 2>/dev/null || hostname)
  for i in "${!CFG_SOURCE[@]}"; do
    entry_enabled "$i" || continue
    s=${CFG_SOURCE[i]}; t=${CFG_TARGET[i]}; st=${CFG_STRATEGY[i]:-$DEFAULT_STRATEGY}
    [[ -d $REPO/$s && ! -L $REPO/$s ]] && ty=dir || ty=file
    add_entry "$s" "$t" "$st" "$ty"
  done
  while IFS= read -r -d '' p; do
    p=${p#"$REPO/"}; under_explicit "$p" && continue
    add_entry "$p" "$p" "$DEFAULT_STRATEGY" file
  done < <(find -P "$REPO" \( -path "$REPO/.git" -o -path "$REPO/dots.toml" -o -path "$REPO/bin" -o -path "$REPO/lib" -o -path "$REPO/tests" -o -path "$REPO/README.md" \) -prune -o \( -type f -o -type l \) -print0)
  validate_target_hierarchy
}

validate_target_hierarchy() {
  local i j
  for i in "${!ETARGET[@]}"; do
    [[ ${ETYPE[i]} == dir ]] || continue
    for j in "${!ETARGET[@]}"; do
      [[ $i == "$j" ]] && continue
      [[ ${ETARGET[j]} == "${ETARGET[i]}/"* ]] && die "atomic directory target '${ETARGET[i]}' overlaps '${ETARGET[j]}'"
    done
  done
}

same_link() { [[ -L $2 && $(readlink "$2") == "$1" ]]; }
same_hardlink() { [[ -f $1 && -f $2 && $(stat -c '%d:%i' "$1" 2>/dev/null || stat -f '%d:%i' "$1") == $(stat -c '%d:%i' "$2" 2>/dev/null || stat -f '%d:%i' "$2") ]]; }
same_copy() { if [[ -d $1 && ! -L $1 ]]; then [[ -d $2 && ! -L $2 ]] && diff -r -q "$1" "$2" >/dev/null 2>&1; else [[ -f $2 && ! -L $2 ]] && cmp -s "$1" "$2"; fi; }
inspect_entry() {
  local i=$1 src=$REPO/${ESOURCE[i]} dst=$TARGET_HOME/${ETARGET[i]} st=${ESTRATEGY[i]}
  if [[ ! -e $dst && ! -L $dst ]]; then INSPECT=missing; return; fi
  case $st in symlink) same_link "$src" "$dst" && INSPECT=correct || INSPECT=conflict;; hardlink) same_hardlink "$src" "$dst" && INSPECT=correct || INSPECT=conflict;; copy) same_copy "$src" "$dst" && INSPECT=correct || INSPECT=differs;; esac
}
ensure_parent() {
  local dst=$1 rel=${1#"$TARGET_HOME/"} parent_rel part current=$TARGET_HOME
  [[ $dst == "$TARGET_HOME/"* ]] || die "internal error: target escapes home"
  parent_rel=${rel%/*}
  [[ $parent_rel == "$rel" ]] && return
  IFS=/ read -r -a _parts <<< "$parent_rel"
  for part in "${_parts[@]}"; do
    [[ -n $part ]] || continue
    current=$current/$part
    if [[ -L $current ]]; then die "refusing target beneath symlinked parent: $current"; fi
    if [[ -e $current ]]; then [[ -d $current ]] || die "target parent is not a directory: $current"; else mkdir "$current"; fi
  done
}
replace_target() { local dst=$1; if [[ -L $dst || -f $dst ]]; then rm "$dst"; else rm -rf "$dst"; fi; }
apply_one() {
  local i=$1 src=$REPO/${ESOURCE[i]} dst=$TARGET_HOME/${ETARGET[i]} st=${ESTRATEGY[i]}
  ensure_parent "$dst"
  case $st in symlink) ln -s "$src" "$dst";; hardlink) ln "$src" "$dst" || die "cannot hardlink '${ESOURCE[i]}' (possibly different filesystems)";; copy) if [[ ${ETYPE[i]} == dir ]]; then cp -R "$src" "$dst"; else cp "$src" "$dst"; fi;; esac
}
render_status() {
  local i; for i in "${!ESOURCE[@]}"; do inspect_entry "$i"; case $INSPECT in correct) printf '%s  %s\n' "$(mark "$C_OK" '✓')" "${ETARGET[i]}";; missing) printf '%s  %s  %s\n' "$(mark "$C_ADD" '→')" "${ETARGET[i]}" "${C_DIM}missing${C_RESET}";; differs) printf '%s  %s  %s\n' "$(mark "$C_WARN" '●')" "${ETARGET[i]}" "${C_WARN}differs${C_RESET}";; conflict) printf '%s  %s  %s\n' "$(mark "$C_ERR" '!')" "${ETARGET[i]}" "${C_ERR}conflict${C_RESET}";; esac; done
}
cmd_apply() {
  local force=$1 i created=0 unchanged=0 conflicts=0; printf '%s\n\n' "${C_BOLD}dots apply${C_RESET}"
  for i in "${!ESOURCE[@]}"; do inspect_entry "$i"; case $INSPECT in
    correct) ((++unchanged)); printf '%s %s\n' "$(mark "$C_OK" '✓')" "${ETARGET[i]}";;
    missing) apply_one "$i"; ((++created)); printf '%s %s %s %s\n' "$(mark "$C_ADD" '+')" "${ETARGET[i]}" "${C_DIM}→${C_RESET}" "${ESTRATEGY[i]}";;
    differs|conflict) if (( force )); then ensure_parent "$TARGET_HOME/${ETARGET[i]}"; replace_target "$TARGET_HOME/${ETARGET[i]}"; apply_one "$i"; ((++created)); printf '%s %s %s %s %s\n' "$(mark "$C_ADD" '~')" "${ETARGET[i]}" "${C_DIM}→${C_RESET}" "${ESTRATEGY[i]}" "${C_WARN}(replaced)${C_RESET}"; else ((++conflicts)); printf '%s %s %s\n' "$(mark "$C_ERR" '!')" "${ETARGET[i]}" "${C_ERR}$INSPECT${C_RESET}"; fi;;
  esac; done
  printf '\n%s created, %s unchanged, %s conflict%s\n' "$created" "$unchanged" "$conflicts" "$([[ $conflicts == 1 ]] || printf s)"
  (( conflicts == 0 ))
}
cmd_remove() {
  local wanted=$1 i found=0
  valid_relpath "$wanted" || die "unsafe path '$wanted'"
  for i in "${!ESOURCE[@]}"; do [[ ${ETARGET[i]} == "$wanted" ]] || continue; found=1; inspect_entry "$i"; [[ $INSPECT == correct ]] || die "refusing to remove '$wanted': target is not the expected deployment"; ensure_parent "$TARGET_HOME/$wanted"; replace_target "$TARGET_HOME/$wanted"; printf '%s %s\n' "$(mark "$C_ADD" '−')" "$wanted"; done
  (( found )) || die "'$wanted' is not a managed target"
}
dots_main() {
  init_ui
  case ${1:-} in --help|-h) usage; return;; --version) printf 'dots %s\n' "$DOTS_VERSION"; return;; esac
  local command=${1:-}; shift || true
  case $command in status|apply|remove) ;; *) usage >&2; exit 2;; esac
  find_repo; TARGET_HOME=${DOTS_HOME:-${HOME:?HOME is not set}}; [[ -d $TARGET_HOME ]] || die "home directory does not exist: $TARGET_HOME"; TARGET_HOME=$(cd "$TARGET_HOME" && pwd -P)
  parse_manifest; build_desired
  case $command in
    status) [[ $# == 0 ]] || die 'status takes no arguments'; render_status ;;
    apply) if [[ $# == 0 ]]; then cmd_apply 0; elif [[ $# == 1 && $1 == --force ]]; then cmd_apply 1; else die 'usage: dots apply [--force]'; fi ;;
    remove) [[ $# == 1 ]] || die 'usage: dots remove <path>'; cmd_remove "$1" ;;
  esac
}
