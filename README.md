# dots

`dots` is a small, stateless Bash dotfile manager. A dotfiles repository
mirrors `$HOME`; files are symlinked by default, and `dots.toml` describes only
exceptions. The repository is the source of truth—there is no deployment
database or generated-dotfile layer.

```bash
dots status
dots apply
dots remove .config/nvim
```

Use `dots --repo ~/some-dotfiles status` to select a repository explicitly.
Otherwise discovery is: current directory when it contains `dots.toml`, then
`$DOTS_REPO`, then `~/.dotfiles`. It never walks upward.

## Selectors and overlays

Selectors classify the current machine by executing small Bash commands.
`dots` does not know what an OS, distribution, hostname, architecture, or role
is; a selector is simply `name + Bash command → normalized value → overlay`.
Every selected overlay is a sparse tree of real files and directories, so its
contents can still be symlinked, copied, or hardlinked directly.

The shipped manifest makes the default selectors visible:

```toml
[selectors]
os = """
case "$(uname -s)" in
  Linux)  echo linux ;;
  Darwin) echo macos ;;
esac
"""

distro = """
if [[ -r /etc/os-release ]]; then
  . /etc/os-release
  echo "$ID"
fi
"""

host = "hostname -s"
```

Typical values might be `os = linux`, `distro = omarchy`, and `host = ser8`.
The same defaults apply internally if a dotfiles manifest omits `[selectors]`.

```text
.dotfiles/
├── .bashrc
├── .config/
│   ├── ghostty/config
│   └── nvim/...
├── .dots/
│   ├── os/
│   │   ├── linux/
│   │   └── macos/
│   ├── distro/
│   │   ├── omarchy/
│   │   └── fedora/
│   └── host/
│       ├── ser8/
│       └── thinkpad/
└── dots.toml
```

Every directory below a selector value mirrors `$HOME`. For example,
`.dots/host/ser8/.bashrc` replaces the common `.bashrc` only when `host` is
`ser8`; `.dots/distro/omarchy/.config/omarchy/config` can exist only for that
distribution. `.dots/` is metadata and is never deployed.

Base files have the lowest precedence. With the default selector order:

```text
base < os < distro < host
```

This is not hard-coded: selector definition order determines precedence.
Directories merge sparsely at file level unless a directory is explicitly
listed in `dots.toml`, in which case it is atomic and the highest layer's whole
directory wins.

You can replace the default model entirely:

```toml
[selectors]
platform = "uname -s"
arch = "uname -m"
role = "~/.local/bin/machine-role"
```

This activates `.dots/platform/...`, `.dots/arch/...`, and `.dots/role/...`.
Output and names are lowercased. A non-empty output must use only `a-z`, `0-9`,
`.`, `_`, and `-`; invalid values fail instead of being silently rewritten.
Empty output skips that selector, while a failing command or multiple values is
an error.

## Manifest and safety

The supported TOML subset is intentionally narrow: `[defaults]`,
`[selectors]`, and `["path"]` tables; quoted strings; and triple-quoted
selector command blocks. Entry keys are `strategy` and `target`. Supported
strategies are `symlink`, `copy`, and file-only `hardlink`.

`status` is read-only. `apply` skips conflicts; `apply --force` replaces them.
`remove` only deletes an exact current deployment. Colors are terminal-only and
respect `NO_COLOR`.

## Installation

```bash
git clone <dots-repository>
cd dots
./install.sh
```

This installs a self-contained `~/.local/bin/dots` without modifying `PATH` or
shell startup files. Use `./install.sh --bin-dir "$HOME/bin"` for another
location. `./uninstall.sh [--bin-dir <path>]` removes only that exact command.
