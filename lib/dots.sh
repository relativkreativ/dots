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
Usage: dots [--repo <path>] [--help] [--version] <command>

Commands:
  status          Show the derived deployment state (read-only).
  apply [--force] [path ...]
                  Create selected deployments; without paths, apply all.
  remove <path>   Remove a deployment only when it still matches its source.
  devour <path> [--overlay <selector>]
                  Import an unmanaged HOME file and deploy it.

Options:
  --repo <path>   Use a specific dotfiles repository.

Repository discovery, in order: --repo; the current directory when it contains
dots.toml; DOTS_REPO; then ~/.dotfiles. DOTS_REPO supplies the default
repository location and does not override a dots.toml in the current directory.
DOTS_HOME overrides HOME only as a deployment target, primarily for testing.
Apply and devour paths are logical HOME-relative paths (for example, .config/nvim), not
repository or overlay paths.
EOF
}

valid_relpath() {
  local p=$1
  [[ -n $p && $p != /* && $p != */ && $p != *'//' && $p != . && $p != .. && $p != ../* && $p != */../* && $p != */.. && $p != *$'\n'* ]]
}
valid_selector_token() { [[ $1 =~ ^[a-z0-9._-]+$ ]]; }
lowercase() { printf '%s' "$1" | LC_ALL=C tr 'A-Z' 'a-z'; }

expand_repo_path() {
  case $1 in
    '~') printf '%s' "${HOME:?HOME is not set}" ;;
    '~/'*) printf '%s/%s' "${HOME:?HOME is not set}" "${1:2}" ;;
    *) printf '%s' "$1" ;;
  esac
}

select_repo() {
  local candidate=$1 shown
  candidate=$(expand_repo_path "$candidate")
  if [[ ! -d $candidate || ! -f $candidate/dots.toml ]]; then
    die "$candidate is not a dots repository (dots.toml not found)"
  fi
  REPO=$(cd "$candidate" && pwd -P)
}

find_repo() {
  local cwd
  if [[ -n ${REPO_OPTION:-} ]]; then select_repo "$REPO_OPTION"; return; fi
  cwd=$(pwd -P)
  if [[ -f $cwd/dots.toml ]]; then select_repo "$cwd"; return; fi
  if [[ -n ${DOTS_REPO:-} ]]; then select_repo "$DOTS_REPO"; return; fi
  select_repo "${HOME:?HOME is not set}/.dotfiles"
}

display_repo() {
  if [[ $REPO == "${HOME%/}" ]]; then printf '~';
  elif [[ $REPO == "${HOME%/}/"* ]]; then printf '~/%s' "${REPO#"${HOME%/}/"}";
  else printf '%s' "$REPO"; fi
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

declare -a CFG_SOURCE=() CFG_TARGET=() CFG_STRATEGY=() CFG_KEYS=()
declare -a SELECTOR_NAME=() SELECTOR_COMMAND=() SELECTOR_VALUE=()
default_selectors() {
  SELECTOR_NAME=(os distro host)
  SELECTOR_COMMAND=(
    $'case "$(uname -s)" in\n  Linux)  echo linux ;;\n  Darwin) echo macos ;;\nesac'
    $'if [[ -r /etc/os-release ]]; then\n  . /etc/os-release\n  echo "$ID"\nfi'
    'hostname -s'
  )
}
selector_index_for() {
  local sought=$1 j
  (( ${#SELECTOR_NAME[@]} )) || return 1
  for j in "${!SELECTOR_NAME[@]}"; do [[ ${SELECTOR_NAME[j]} == "$sought" ]] && { SELECTOR_LOOKUP=$j; return 0; }; done
  return 1
}
add_selector() {
  local name=$1 command=$2
  name=$(lowercase "$name")
  valid_selector_token "$name" || die "invalid selector name '$name'"
  selector_index_for "$name" && die "duplicate selector '$name'"
  [[ -n $command ]] || die "selector '$name' has an empty command"
  SELECTOR_NAME+=("$name"); SELECTOR_COMMAND+=("$command")
}
cfg_index_for() {
  local sought=$1 j
  (( ${#CFG_SOURCE[@]} )) || return 1
  for j in "${!CFG_SOURCE[@]}"; do [[ ${CFG_SOURCE[j]} == "$sought" ]] && { CFG_LOOKUP=$j; return 0; }; done
  return 1
}
parse_manifest() {
  local file=$REPO/dots.toml raw line n=0 section= key value source i defaults_keys= selectors_seen=0 triple_key= triple_value=
  CFG_SOURCE=(); CFG_TARGET=(); CFG_STRATEGY=(); CFG_KEYS=()
  SELECTOR_NAME=(); SELECTOR_COMMAND=(); SELECTOR_VALUE=()
  DEFAULT_STRATEGY=symlink
  default_selectors
  [[ -f $file ]] || die "dots.toml is required for repository discovery and metadata"
  while IFS= read -r raw || [[ -n $raw ]]; do
    ((++n))
    if [[ -n $triple_key ]]; then
      line=$(trim "$raw")
      if [[ $line == '"""' ]]; then
        add_selector "$triple_key" "$triple_value"
        triple_key= triple_value=
      else
        triple_value+="$raw"$'\n'
      fi
      continue
    fi
    line=$raw
    line=${line%%#*}; line=$(trim "$line"); [[ -z $line ]] && continue
    if [[ $line =~ ^\[defaults\]$ ]]; then section=defaults; continue; fi
    if [[ $line =~ ^\[selectors\]$ ]]; then
      if (( ! selectors_seen )); then SELECTOR_NAME=(); SELECTOR_COMMAND=(); selectors_seen=1; fi
      section=selectors; continue
    fi
    if [[ $line =~ ^\[\"([^\"]+)\"\]$ ]]; then
      source=${BASH_REMATCH[1]}; valid_relpath "$source" || die "dots.toml:$n: unsafe source path"
      if cfg_index_for "$source"; then die "dots.toml:$n: duplicate table '$source'"; fi
      i=${#CFG_SOURCE[@]}; CFG_SOURCE+=("$source"); CFG_TARGET+=("$source"); CFG_STRATEGY+=(""); CFG_KEYS+=("|"); section=$source; continue
    fi
    [[ $line =~ ^([A-Za-z0-9._-]+)[[:space:]]*=[[:space:]]*(.*)$ ]] || die "dots.toml:$n: unsupported syntax"
    key=${BASH_REMATCH[1]}; value=${BASH_REMATCH[2]}
    if [[ $section == defaults ]]; then
      [[ $key == strategy ]] || die "dots.toml:$n: only defaults.strategy is supported"
      [[ $defaults_keys != *"|$key|"* ]] || die "dots.toml:$n: duplicate key '$key'"
      defaults_keys="${defaults_keys}|$key|"
      DEFAULT_STRATEGY=$(unquote "$value") || die "dots.toml:$n: expected a simple quoted string"
      continue
    fi
    if [[ $section == selectors ]]; then
      if [[ $value == '"""' ]]; then triple_key=$key; triple_value=; continue; fi
      value=$(unquote "$value") || die "dots.toml:$n: selector commands must be quoted strings or triple-quoted blocks"
      add_selector "$key" "$value"
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
      *) die "dots.toml:$n: unsupported key '$key'" ;;
    esac
  done < "$file"
  [[ -z $triple_key ]] || die "dots.toml:$n: unterminated selector command for '$triple_key'"
  case $DEFAULT_STRATEGY in symlink|hardlink|copy) ;; *) die "invalid defaults.strategy '$DEFAULT_STRATEGY'";; esac
}

evaluate_selectors() {
  local i j output line value count
  SELECTOR_VALUE=()
  (( ${#SELECTOR_NAME[@]} )) || return 0
  for i in "${!SELECTOR_NAME[@]}"; do
    output=$(bash -c "${SELECTOR_COMMAND[i]}") || die "selector '${SELECTOR_NAME[i]}' failed"
    value= count=0
    while IFS= read -r line || [[ -n $line ]]; do
      line=$(trim "$line")
      [[ -z $line ]] && continue
      value=$line; ((++count))
    done <<< "$output"
    (( count <= 1 )) || die "selector '${SELECTOR_NAME[i]}' produced multiple values"
    value=$(lowercase "$value")
    if [[ -n $value ]] && ! valid_selector_token "$value"; then
      die "selector '${SELECTOR_NAME[i]}' returned invalid value '$value' (allowed characters: a-z, 0-9, ., _, -)"
    fi
    if [[ -n $value ]]; then
      if (( ${#SELECTOR_VALUE[@]} )); then
        for j in "${!SELECTOR_VALUE[@]}"; do
          [[ ${SELECTOR_VALUE[j]} != "$value" ]] || die "selectors '${SELECTOR_NAME[j]}' and '${SELECTOR_NAME[i]}' both resolve to '$value' (overlay directory '_$value' would be ambiguous)"
        done
      fi
    fi
    SELECTOR_VALUE+=("$value")
  done
}

declare -a LAYER_ROOT=() LAYER_LABEL=() ESOURCE=() ESOURCE_LAYER=() ELOGICAL=() ETARGET=() ESTRATEGY=() ETYPE=()
declare -a RESOLVED_LOGICAL=() RESOLVED_SOURCE=()
resolved_index_for() { local wanted=$1 j; (( ${#RESOLVED_LOGICAL[@]} )) || return 1; for j in "${!RESOLVED_LOGICAL[@]}"; do [[ ${RESOLVED_LOGICAL[j]} == "$wanted" ]] && { RESOLVED_LOOKUP=$j; return 0; }; done; return 1; }
set_resolved() { local logical=$1 physical=$2; if resolved_index_for "$logical"; then RESOLVED_SOURCE[RESOLVED_LOOKUP]=$physical; else RESOLVED_LOGICAL+=("$logical"); RESOLVED_SOURCE+=("$physical"); fi; }
resolved_source_for() { resolved_index_for "$1" && { RESOLVED_RESULT=${RESOLVED_SOURCE[RESOLVED_LOOKUP]}; return 0; }; return 1; }
add_entry() {
  local physical=$1 logical=$2 t=$3 st=$4 ty=$5 existing layer=base i
  valid_relpath "$logical" || die "unsafe source path '$logical'"; valid_relpath "$t" || die "unsafe target path '$t'"
  case $st in symlink|hardlink|copy) ;; *) die "invalid strategy '$st' for '$logical'";; esac
  [[ -e $physical || -L $physical ]] || die "source does not exist: $logical"
  [[ $physical == "$REPO/"* ]] || die "source escapes repository: $logical"
  [[ $st != hardlink || $ty == file ]] || die "cannot hardlink directory '$logical'"
  if (( ${#ETARGET[@]} )); then for existing in "${ETARGET[@]}"; do [[ $existing != "$t" ]] || die "conflicting target definitions for '$t'"; done; fi
  if (( ${#LAYER_ROOT[@]} )); then for i in "${!LAYER_ROOT[@]}"; do [[ $physical == "${LAYER_ROOT[i]}/"* ]] && layer=${LAYER_LABEL[i]}; done; fi
  ESOURCE+=("$physical"); ESOURCE_LAYER+=("$layer"); ELOGICAL+=("$logical"); ETARGET+=("$t"); ESTRATEGY+=("$st"); ETYPE+=("$ty")
}
under_explicit() { local p=$1 x; (( ${#CFG_SOURCE[@]} )) || return 1; for x in "${CFG_SOURCE[@]}"; do [[ $p == "$x" || $p == "$x/"* ]] && return 0; done; return 1; }
exists_in_inactive_overlay() {
  local logical=$1 root
  # Active layers have already been checked by build_desired.  Here we only
  # establish that an otherwise missing configured source is real repository
  # content for another machine, rather than a manifest mistake.
  for root in "$REPO"/_*; do
    [[ -d $root && ! -L $root ]] || continue
    [[ -e $root/$logical || -L $root/$logical ]] && return 0
  done
  return 1
}
build_desired() {
  local i s t st p ty root logical source layer source_type seen_type
  [[ ${BUILD_SKIP_SELECTORS:-} == 1 ]] || evaluate_selectors
  ESOURCE=(); ESOURCE_LAYER=(); ELOGICAL=(); ETARGET=(); ESTRATEGY=(); ETYPE=()
  LAYER_ROOT=("$REPO"); LAYER_LABEL=(base)
  if (( ${#SELECTOR_NAME[@]} )); then
    for i in "${!SELECTOR_NAME[@]}"; do
      [[ -n ${SELECTOR_VALUE[i]} ]] || continue
      root=$REPO/_${SELECTOR_VALUE[i]}
      [[ -d $root && ! -L $root ]] || continue
      LAYER_ROOT+=("$root"); LAYER_LABEL+=("_${SELECTOR_VALUE[i]}")
    done
  fi
  RESOLVED_LOGICAL=(); RESOLVED_SOURCE=()
  for layer in "${!LAYER_ROOT[@]}"; do
    root=${LAYER_ROOT[layer]}
    while IFS= read -r -d '' p; do
      logical=${p#"$root/"}
      [[ $layer != 0 || $logical != _*/* ]] || continue
      [[ $layer != 0 || $logical != .gitignore ]] || continue
      set_resolved "$logical" "$p"
    done < <(
      find -P "$root" \( -path "$root/.git" -o -path "$root/dots.toml" \) -prune -o \( -type f -o -type l \) -print0
    )
  done
  validate_resolved_hierarchy
  sort_resolved
  if (( ${#CFG_SOURCE[@]} )); then for i in "${!CFG_SOURCE[@]}"; do
    s=${CFG_SOURCE[i]}; t=${CFG_TARGET[i]}; st=${CFG_STRATEGY[i]:-$DEFAULT_STRATEGY}
    [[ $s != .gitignore ]] || die "repository metadata cannot be managed: .gitignore"
    [[ $s == */* || $s != _* || ! -d $REPO/$s ]] || die "top-level overlay directory '$s' cannot be a managed entry"
    source= seen_type=
    for layer in "${!LAYER_ROOT[@]}"; do
      root=${LAYER_ROOT[layer]}
      [[ -e $root/$s || -L $root/$s ]] || continue
      if [[ -d $root/$s && ! -L $root/$s ]]; then source_type=dir; else source_type=file; fi
      [[ -z $seen_type || $seen_type == "$source_type" ]] || die "file/directory type conflict at '$s'"
      seen_type=$source_type; source=$root/$s
    done
    if [[ -z $source ]]; then
      [[ ${DEVOUR_ALLOW_MISSING:-} == "$s" ]] && continue
      exists_in_inactive_overlay "$s" && continue
      die "source does not exist: $s"
    fi
    if [[ -d $source && ! -L $source ]]; then ty=dir; else ty=file; fi
    add_entry "$source" "$s" "$t" "$st" "$ty"
  done; fi
  if (( ${#RESOLVED_LOGICAL[@]} )); then for i in "${!RESOLVED_LOGICAL[@]}"; do
    logical=${RESOLVED_LOGICAL[i]}; under_explicit "$logical" && continue
    add_entry "${RESOLVED_SOURCE[i]}" "$logical" "$logical" "$DEFAULT_STRATEGY" file
  done; fi
  validate_target_hierarchy
}

sort_resolved() {
  local i j temp
  (( ${#RESOLVED_LOGICAL[@]} )) || return 0
  for ((i = 0; i < ${#RESOLVED_LOGICAL[@]}; i++)); do
    for ((j = i + 1; j < ${#RESOLVED_LOGICAL[@]}; j++)); do
      [[ ${RESOLVED_LOGICAL[j]} < ${RESOLVED_LOGICAL[i]} ]] || continue
      temp=${RESOLVED_LOGICAL[i]}; RESOLVED_LOGICAL[i]=${RESOLVED_LOGICAL[j]}; RESOLVED_LOGICAL[j]=$temp
      temp=${RESOLVED_SOURCE[i]}; RESOLVED_SOURCE[i]=${RESOLVED_SOURCE[j]}; RESOLVED_SOURCE[j]=$temp
    done
  done
}

validate_resolved_hierarchy() {
  local i j a b
  (( ${#RESOLVED_LOGICAL[@]} )) || return 0
  for i in "${!RESOLVED_LOGICAL[@]}"; do
    a=${RESOLVED_LOGICAL[i]}
    for j in "${!RESOLVED_LOGICAL[@]}"; do
      [[ $i == "$j" ]] && continue
      b=${RESOLVED_LOGICAL[j]}
      [[ $b == "$a/"* ]] && die "file/directory type conflict at '$a'"
    done
  done
}

validate_target_hierarchy() {
  local i j
  (( ${#ETARGET[@]} )) || return 0
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
classify_conflict() {
  local dst=$1
  if [[ -L $dst ]]; then
    [[ -e $dst ]] && INSPECT_REASON=wrong_symlink || INSPECT_REASON=broken_symlink
  elif [[ -f $dst ]]; then
    INSPECT_REASON=file
  elif [[ -d $dst ]]; then
    INSPECT_REASON=directory
  else
    INSPECT_REASON=other
  fi
}
conflict_label() {
  case $1 in broken_symlink) printf 'broken symlink';; wrong_symlink) printf 'wrong symlink';; file) printf 'file conflict';; directory) printf 'directory conflict';; *) printf 'other conflict';; esac
}
inspect_entry() {
  local i=$1 src=${ESOURCE[i]} dst=$TARGET_HOME/${ETARGET[i]} st=${ESTRATEGY[i]}
  INSPECT_REASON=
  if [[ ! -L $dst && ! -e $dst ]]; then INSPECT=missing; return; fi
  case $st in symlink) same_link "$src" "$dst" && INSPECT=correct || INSPECT=conflict;; hardlink) same_hardlink "$src" "$dst" && INSPECT=correct || INSPECT=conflict;; copy) same_copy "$src" "$dst" && INSPECT=correct || INSPECT=conflict;; esac
  [[ $INSPECT == correct ]] || classify_conflict "$dst"
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
  local i=$1 src=${ESOURCE[i]} dst=$TARGET_HOME/${ETARGET[i]} st=${ESTRATEGY[i]}
  ensure_parent "$dst"
  case $st in symlink) ln -s "$src" "$dst";; hardlink) ln "$src" "$dst";; copy) if [[ ${ETYPE[i]} == dir ]]; then cp -R "$src" "$dst"; else cp "$src" "$dst"; fi;; esac
}
render_status() {
  local i shown=0; printf '%sdots  %s%s\n' "$C_DIM" "$(display_repo)" "$C_RESET"
  if (( ${#SELECTOR_NAME[@]} )); then for i in "${!SELECTOR_NAME[@]}"; do [[ -n ${SELECTOR_VALUE[i]} ]] || continue; ((++shown)); done; fi
  if (( shown )); then
    printf '%sSelectors%s\n' "$C_DIM" "$C_RESET"
    if (( ${#SELECTOR_NAME[@]} )); then for i in "${!SELECTOR_NAME[@]}"; do [[ -n ${SELECTOR_VALUE[i]} ]] || continue; printf '  %-12s %s\n' "${SELECTOR_NAME[i]}" "${SELECTOR_VALUE[i]}"; done; fi
  fi
  printf '\n'
  if (( ${#ESOURCE[@]} )); then for i in "${!ESOURCE[@]}"; do inspect_entry "$i"; case $INSPECT in correct) printf '%s  %s\n' "$(mark "$C_OK" '✓')" "${ETARGET[i]}";; missing) printf '%s  %s  %s\n' "$(mark "$C_ADD" '→')" "${ETARGET[i]}" "${C_DIM}missing${C_RESET}";; conflict) printf '%s  %s  %s\n' "$(mark "$C_ERR" '!')" "${ETARGET[i]}" "${C_ERR}$(conflict_label "$INSPECT_REASON")${C_RESET}";; esac; done; fi
}
declare -a APPLY_INDEX=()
select_apply_entries() {
  local requested selected i j atomic
  APPLY_INDEX=()
  [[ $# -gt 0 ]] || { if (( ${#ESOURCE[@]} )); then APPLY_INDEX=("${!ESOURCE[@]}"); fi; return; }
  for requested in "$@"; do
    valid_relpath "$requested" || die "unsafe path selector: $requested"
    selected=
    if (( ${#ETARGET[@]} )); then for i in "${!ETARGET[@]}"; do
      [[ ${ETARGET[i]} == "$requested" ]] && { selected=$i; break; }
    done; fi
    if [[ -z $selected ]]; then
      if (( ${#ETARGET[@]} )); then for i in "${!ETARGET[@]}"; do
        [[ ${ETYPE[i]} == dir && $requested == "${ETARGET[i]}/"* ]] || continue
        die "'$requested' is part of atomic directory '${ETARGET[i]}'; apply '${ETARGET[i]}' instead"
      done; fi
      die "path is not managed by dots: $requested"
    fi
    if (( ${#APPLY_INDEX[@]} )); then for j in "${APPLY_INDEX[@]}"; do [[ $j != "$selected" ]] || { selected=; break; }; done; fi
    [[ -n $selected ]] && APPLY_INDEX+=("$selected")
  done
  # Preserve desired-state ordering, rather than argument or filesystem order.
  if (( ${#APPLY_INDEX[@]} )); then selected=("${APPLY_INDEX[@]}"); else selected=(); fi; APPLY_INDEX=()
  if (( ${#ESOURCE[@]} )); then for i in "${!ESOURCE[@]}"; do
    if (( ${#selected[@]} )); then for j in "${selected[@]}"; do [[ $i == "$j" ]] && APPLY_INDEX+=("$i"); done; fi
  done; fi
  return 0
}
cmd_apply() {
  local force=$1 i created=0 unchanged=0 conflicts=0
  shift
  select_apply_entries "$@"
  printf '%s\n\n' "${C_BOLD}dots apply${C_RESET}"
  if (( ${#APPLY_INDEX[@]} )); then for i in "${APPLY_INDEX[@]}"; do inspect_entry "$i"; case $INSPECT in
    correct) ((++unchanged)); printf '%s %s\n' "$(mark "$C_OK" '✓')" "${ETARGET[i]}";;
    missing) apply_one "$i" || { [[ ${ESTRATEGY[i]} != hardlink ]] || die "cannot hardlink '${ESOURCE[i]}' (possibly different filesystems)"; die "cannot deploy '${ETARGET[i]}'"; }; ((++created)); printf '%s %s %s %s\n' "$(mark "$C_ADD" '+')" "${ETARGET[i]}" "${C_DIM}→${C_RESET}" "${ESTRATEGY[i]}";;
    conflict) if (( force )); then ensure_parent "$TARGET_HOME/${ETARGET[i]}"; replace_target "$TARGET_HOME/${ETARGET[i]}"; apply_one "$i" || { [[ ${ESTRATEGY[i]} != hardlink ]] || die "cannot hardlink '${ESOURCE[i]}' (possibly different filesystems)"; die "cannot deploy '${ETARGET[i]}'"; }; ((++created)); printf '%s %s %s %s %s\n' "$(mark "$C_ADD" '~')" "${ETARGET[i]}" "${C_DIM}→${C_RESET}" "${ESTRATEGY[i]}" "${C_WARN}(replaced)${C_RESET}"; else ((++conflicts)); printf '%s %s  %s\n' "$(mark "$C_ERR" '!')" "${ETARGET[i]}" "${C_ERR}$(conflict_label "$INSPECT_REASON")${C_RESET}"; fi;;
  esac; done; fi
  printf '\n%s created, %s unchanged, %s conflict%s\n' "$created" "$unchanged" "$conflicts" "$([[ $conflicts == 1 ]] || printf s)"
  (( conflicts == 0 ))
}
cmd_remove() {
  local wanted=$1 i found=0
  valid_relpath "$wanted" || die "unsafe path '$wanted'"
  if (( ${#ESOURCE[@]} )); then for i in "${!ESOURCE[@]}"; do [[ ${ETARGET[i]} == "$wanted" ]] || continue; found=1; inspect_entry "$i"; [[ $INSPECT == correct ]] || die "refusing to remove '$wanted': target is not the expected deployment"; ensure_parent "$TARGET_HOME/$wanted"; replace_target "$TARGET_HOME/$wanted"; printf '%s %s\n' "$(mark "$C_ADD" '−')" "$wanted"; done; fi
  (( found )) || die "'$wanted' is not a managed target"
}
devour_repo_parent() {
  local dst=$1 rel=${1#"$REPO/"} parent_rel part current=$REPO
  [[ $dst == "$REPO/"* ]] || die "internal error: repository destination escapes repository"
  parent_rel=${rel%/*}
  [[ $parent_rel == "$rel" ]] && return
  IFS=/ read -r -a _parts <<< "$parent_rel"
  for part in "${_parts[@]}"; do
    [[ -n $part ]] || continue
    current=$current/$part
    if [[ -L $current ]]; then die "refusing repository destination beneath symlinked parent: $current"; fi
    if [[ -e $current ]]; then [[ -d $current ]] || die "repository destination parent is not a directory: $current"; else mkdir "$current"; fi
  done
}
devour_reject_path() {
  local p=$1 first
  valid_relpath "$p" || die "unsafe logical path '$p'"
  case $p in dots.toml|dots.toml/*|.git|.git/*|.gitignore) die "repository metadata cannot be devoured: $p";; esac
  first=${p%%/*}
  [[ $p != "$first"/* || $first != _* ]] || die "top-level overlay path cannot be devoured: $p"
}
devour_entry_for_logical() {
  local wanted=$1 i
  (( ${#ELOGICAL[@]} )) || return 1
  for i in "${!ELOGICAL[@]}"; do [[ ${ELOGICAL[i]} == "$wanted" ]] && { DEVOUR_ENTRY=$i; return 0; }; done
  return 1
}
devour_atomic_check() {
  local wanted=$1 i
  (( ${#ELOGICAL[@]} )) || return 0
  for i in "${!ELOGICAL[@]}"; do
    [[ ${ETYPE[i]} == dir && $wanted == "${ELOGICAL[i]}/"* ]] || continue
    die "'$wanted' is part of atomic directory '${ELOGICAL[i]}'\n       '${ELOGICAL[i]}' is the managed deployment unit"
  done
}
devour_atomic_children_check() {
  local wanted=$1 configured
  (( ${#CFG_SOURCE[@]} )) || return 0
  for configured in "${CFG_SOURCE[@]}"; do
    [[ $configured == "$wanted/"* ]] || continue
    die "'$wanted' would be an atomic directory containing explicit managed entry '$configured'"
  done
}
devour_validate_directory_tree() {
  local source=$1 unsafe
  unsafe=$(find -P "$source" \( -type d -o -type f -o -type l \) -o -print -quit)
  [[ -z $unsafe ]] || die "directory '$source' contains unsupported filesystem object '$unsafe'"
}
append_atomic_manifest() {
  local logical=$1
  # The parser accepts this exact table syntax. Appending avoids changing any
  # user-authored comments, whitespace, ordering, or existing tables.
  printf '\n["%s"]\n' "$logical" >> "$REPO/dots.toml" || die "could not add atomic entry for '$logical' to dots.toml"
}
restore_devoured_directory() {
  local source=$1 destination=$2
  if [[ -L $source || -e $source ]]; then replace_target "$source"; fi
  cp -a "$destination" "$source" || warn "could not restore '$source' after deployment failure"
}
cmd_devour_directory() {
  local logical=$1 selector=$2 source=$3 destination=$4 layer=$5 i existing=0 strategy selector_values=()
  if cfg_index_for "$logical"; then
    existing=1
    strategy=${CFG_STRATEGY[CFG_LOOKUP]:-$DEFAULT_STRATEGY}
  else
    strategy=$DEFAULT_STRATEGY
  fi
  [[ $strategy != hardlink ]] || die "cannot hardlink directory '$logical'"
  devour_atomic_check "$logical"
  devour_atomic_children_check "$logical"
  devour_validate_directory_tree "$source"
  [[ ! -e $destination && ! -L $destination ]] || die "repository destination already exists: $destination"
  devour_repo_parent "$destination"
  cp -a "$source" "$destination" || die "could not copy directory '$logical' into repository"
  [[ -d $destination && ! -L $destination ]] || die "directory copy verification failed for '$logical'"
  (( existing )) || append_atomic_manifest "$logical"
  # Parse the appended table, but retain the already validated selector values
  # so selector evaluation cannot introduce a post-copy surprise.
  if (( ${#SELECTOR_VALUE[@]} )); then selector_values=("${SELECTOR_VALUE[@]}"); fi
  parse_manifest
  SELECTOR_VALUE=("${selector_values[@]}")
  BUILD_SKIP_SELECTORS=1 build_desired
  devour_entry_for_logical "$logical" || die "imported directory did not enter desired state: $logical"
  i=$DEVOUR_ENTRY
  [[ ${ETYPE[i]} == dir ]] || die "imported directory is not an atomic deployment unit: $logical"
  if ! rm -rf -- "$source"; then
    restore_devoured_directory "$source" "$destination"
    die "could not remove original directory '$logical' after import"
  fi
  inspect_entry "$i"
  if [[ $INSPECT != missing ]] || ! apply_one "$i"; then
    restore_devoured_directory "$source" "$destination"
    die "could not deploy '$logical' after import"
  fi
  inspect_entry "$i"
  if [[ $INSPECT != correct ]]; then
    restore_devoured_directory "$source" "$destination"
    die "deployment verification failed for '$logical'"
  fi
  printf '%s\n\n' "${C_BOLD}dots devour${C_RESET}"
  printf '%s %s %s %s %s\n' "$(mark "$C_ADD" '+')" "$logical" "${C_DIM}→${C_RESET}" "$layer" "${C_DIM}(atomic)${C_RESET}"
  printf '%s %s %s %s\n' "$(mark "$C_OK" '✓')" "$logical" "${C_DIM}→${C_RESET}" "${ESTRATEGY[i]}"
}
cmd_devour() {
  local logical=$1 selector=${2:-} source destination layer=base i
  devour_reject_path "$logical"
  if [[ -n $selector ]]; then
    selector_index_for "$selector" || die "unknown selector '$selector'"
    i=$SELECTOR_LOOKUP
    [[ -n ${SELECTOR_VALUE[i]} ]] || die "selector '$selector' resolved to an empty value; no overlay is available"
    layer=_${SELECTOR_VALUE[i]}
  fi
  source=$TARGET_HOME/$logical
  [[ -L $source ]] && die "'$logical' is a symlink\n       devour does not support symlinks"
  [[ -e $source ]] || die "'$logical' does not exist under HOME"
  if [[ -d $source ]]; then
    if [[ $layer == base ]]; then destination=$REPO/$logical; else destination=$REPO/$layer/$logical; fi
    cmd_devour_directory "$logical" "$selector" "$source" "$destination" "$layer"
    return
  fi
  [[ -f $source ]] || die "'$logical' is not a regular file\n       devour currently supports regular files only"
  devour_entry_for_logical "$logical" && die "'$logical' is already managed by dots"
  devour_atomic_check "$logical"
  if [[ $layer == base ]]; then destination=$REPO/$logical; else destination=$REPO/$layer/$logical; fi
  [[ ! -e $destination && ! -L $destination ]] || die "repository destination already exists: $destination"
  devour_repo_parent "$destination"
  cp -p "$source" "$destination" || die "could not copy '$logical' into repository"
  # Rebuild through the ordinary resolver so the newly imported file gets its
  # manifest strategy, overlay precedence, and normal deployment behavior.
  DEVOUR_ALLOW_MISSING=
  BUILD_SKIP_SELECTORS=1 build_desired
  devour_entry_for_logical "$logical" || die "imported path did not enter desired state: $logical"
  i=$DEVOUR_ENTRY
  rm "$source"
  inspect_entry "$i"
  if [[ $INSPECT != missing ]] || ! apply_one "$i"; then
    [[ $INSPECT != missing ]] || cp -p "$destination" "$source" || warn "could not restore '$logical' after deployment failure"
    die "could not deploy '$logical' after import"
  fi
  inspect_entry "$i"
  [[ $INSPECT == correct ]] || { cp -p "$destination" "$source" || warn "could not restore '$logical' after verification failure"; die "deployment verification failed for '$logical'"; }
  printf '%s\n\n' "${C_BOLD}dots devour${C_RESET}"
  printf '%s %s %s %s\n' "$(mark "$C_ADD" '+')" "$logical" "${C_DIM}→${C_RESET}" "$layer"
  printf '%s %s %s %s\n' "$(mark "$C_OK" '✓')" "$logical" "${C_DIM}→${C_RESET}" "${ESTRATEGY[i]}"
}
dots_main() {
  init_ui
  local command= arg repo_seen=0 args=()
  while [[ $# -gt 0 ]]; do
    case $1 in
      --help|-h) usage; return ;;
      --version) printf 'dots %s\n' "$DOTS_VERSION"; return ;;
      --repo) [[ $# -ge 2 ]] || die '--repo requires a path'; (( repo_seen == 0 )) || die '--repo may only be specified once'; REPO_OPTION=$2; repo_seen=1; shift 2 ;;
      *) args+=("$1"); shift ;;
    esac
  done
  [[ ${#args[@]} -gt 0 ]] || { usage >&2; exit 2; }
  command=${args[0]}; set -- "${args[@]:1}"
  case $command in status|apply|remove|devour) ;; *) usage >&2; exit 2;; esac
  find_repo; TARGET_HOME=${DOTS_HOME:-${HOME:?HOME is not set}}; [[ -d $TARGET_HOME ]] || die "home directory does not exist: $TARGET_HOME"; TARGET_HOME=$(cd "$TARGET_HOME" && pwd -P)
  parse_manifest
  # A manifest may predeclare the strategy for the file being imported. Allow
  # just that not-yet-present source during the pre-import desired-state pass.
  if [[ $command == devour ]]; then
    local devour_next_is_selector=0
    for arg in "$@"; do
      if (( devour_next_is_selector )); then devour_next_is_selector=0; continue; fi
      case $arg in --overlay|-o) devour_next_is_selector=1;; --*) ;; *) DEVOUR_ALLOW_MISSING=$arg; break;; esac
    done
  fi
  build_desired
  DEVOUR_ALLOW_MISSING=
  case $command in
    status) [[ $# == 0 ]] || die 'status takes no arguments'; render_status ;;
    apply)
      local force=0 apply_paths=() arg
      for arg in "$@"; do
        if [[ $arg == --force ]]; then
          (( force == 0 )) || die '--force may only be specified once'
          force=1
        else
          apply_paths+=("$arg")
        fi
      done
      cmd_apply "$force" "${apply_paths[@]}"
      ;;
    remove) [[ $# == 1 ]] || die 'usage: dots remove <path>'; cmd_remove "$1" ;;
    devour)
      local logical= overlay= arg
      while [[ $# -gt 0 ]]; do
        case $1 in
          --overlay|-o) [[ $# -ge 2 ]] || die "$1 requires a selector name"; [[ -z $overlay ]] || die '--overlay may only be specified once'; overlay=$2; shift 2 ;;
          --*) die "unknown devour option: $1" ;;
          *) [[ -z $logical ]] || die 'usage: dots devour <path> [--overlay <selector>]'; logical=$1; shift ;;
        esac
      done
      [[ -n $logical ]] || die 'usage: dots devour <path> [--overlay <selector>]'
      cmd_devour "$logical" "$overlay"
      ;;
  esac
}
