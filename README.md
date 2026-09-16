# dots

`dots` is a small Bash dotfile manager. A repository mirrors `$HOME`; ordinary
files are symlinked to the same relative path. `dots.toml` records only
exceptions, such as atomic directories, copies, hardlinks, target remapping,
and OS/host conditions.

```bash
bin/dots --repo ~/some-dotfiles status
bin/dots --repo ~/some-dotfiles apply
bin/dots --repo ~/some-dotfiles remove .config/nvim
```

Repository discovery is deliberately direct and stateless: `--repo <path>`;
the current directory if it directly contains `dots.toml`; `$DOTS_REPO`; then
`~/.dotfiles`. It never walks upward. The canonical form is `dots --repo <path>
<command>`; `~` and `~/…` supplied as a quoted option value refer to the current
user's home directory. Every selected directory must contain `dots.toml`.
`DOTS_HOME` overrides `$HOME` only as a deployment target for tests.

The manifest is deliberately a small TOML subset: `[defaults]` and
`["path"]` tables; simple quoted strings; and arrays of simple quoted strings.
Supported keys are `strategy`, `target`, `os`, and `hosts`. Escapes, inline
tables, multiline values, and other TOML features are rejected. Metadata
(`dots.toml`, `.git`) is never scanned. This repository also reserves its own
`bin/`, `lib/`, `tests/`, and `README.md` as tool internals.

`status` is read-only. `apply` skips conflicts; `apply --force` replaces them.
`remove` only deletes a target that currently exactly matches its expected
deployment. Colors are enabled only for a terminal and are disabled by
`NO_COLOR`.

## Installation

Clone this application repository and run its installer:

```bash
git clone <dots-repository>
cd dots
./install.sh
```

It installs a self-contained copy to `~/.local/bin/dots` and never changes
`PATH` or shell startup files. Add `~/.local/bin` to `PATH` yourself if needed.
Use `./install.sh --bin-dir "$HOME/bin"` for another location.

## Uninstallation

The matching `./uninstall.sh [--bin-dir <path>]` removes only that exact
executable and leaves its containing directory untouched.
