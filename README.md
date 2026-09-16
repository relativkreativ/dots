# dots

`dots` is a small Bash dotfile manager. A repository mirrors `$HOME`; ordinary
files are symlinked to the same relative path. `dots.toml` records only
exceptions, such as atomic directories, copies, hardlinks, target remapping,
and OS/host conditions.

```bash
DOTS_REPO=$PWD bin/dots status
DOTS_REPO=$PWD bin/dots apply
DOTS_REPO=$PWD bin/dots remove .config/nvim
```

Discovery uses `DOTS_REPO`, or walks upward from the current directory until it
finds `dots.toml`. It stores no state. `DOTS_HOME` overrides `$HOME` for tests.

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
