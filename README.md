# dots

`dots` is a small, stateless Bash dotfile manager. Your dotfiles repository
mirrors `$HOME`: normal files map to the same relative paths and are symlinked
by default. `dots.toml` describes exceptions, while selectors activate sparse
machine-specific overlays.

```text
dotfiles/
├── dots.toml
├── .bashrc
├── .gitconfig
├── .config/
│   ├── ghostty/
│   └── nvim/
├── _linux/
├── _omarchy/
└── _ser8/
```

If a file is not part of the desired `$HOME` state, it should not live in the
dotfiles repository. There is intentionally no ignore mechanism.

## Install dots

```bash
git clone <dots-repository>
cd dots
./install.sh
```

This copies one self-contained executable to `~/.local/bin/dots`; the clone
may then be removed. It does not change `PATH` or shell startup files. Remove
it with `./uninstall.sh` (or remove that one executable directly). Both scripts
accept `--bin-dir <path>`.

The application repository is not a dotfiles repository. Copy its sample to
start one:

```bash
mkdir -p ~/.dotfiles
cp /path/to/dots/dots.toml.sample ~/.dotfiles/dots.toml
cd ~/.dotfiles
dots status
```

Repository discovery is: `--repo <path>`, the current directory when it
directly contains `dots.toml`, `$DOTS_REPO`, then `~/.dotfiles`. It never walks
upward; `dots.toml.sample` does not qualify.

## Selectors and overlays

A selector is simply `name + Bash command → normalized value → overlay`.
`dots` gives no special meaning to names such as OS, distro, host, arch, or
role. The default selectors, included visibly in the sample, are:

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

For `os = linux`, `distro = omarchy`, and `host = ser8`, active layers are:

```text
base < _linux < _omarchy < _ser8
```

That order comes from selector definition order, not hard-coded knowledge of
the names. Each top-level `_<value>/` directory mirrors `$HOME`. Thus
`_ser8/.bashrc` overrides `.bashrc`, and an overlay-only file such as
`_omarchy/.config/omarchy/config` is also deployed. Overlays are sparse: files
not present in an overlay continue to come from lower-precedence layers.

Only top-level underscore **directories** are reserved overlays. A nested path
such as `.config/app/_cache/file` is ordinary content; ordinary underscore
files are ordinary content too. Inactive overlay directories are ignored.

Selector output and selector names are lowercased. Non-empty values must use
only `a-z`, `0-9`, `.`, `_`, and `-`; invalid values fail rather than being
silently sanitized. Empty output contributes no layer. Two active selectors
cannot resolve to the same value, because that would make one overlay
ambiguous. Custom selectors are straightforward:

```toml
[selectors]
platform = "uname -s"
arch = "uname -m"
role = "~/.local/bin/machine-role"
```

## Deployment behavior

`dots status`, `dots apply`, and `dots remove <path>` derive all state from the
repository, manifest, and `$HOME`. A manifest entry always names the logical
path, regardless of which layer supplies its physical source:

```toml
[".config/example"]
strategy = "copy"

[".config/nvim"]
# An explicitly configured directory is atomic: its highest layer wins whole.
```

Strategies are `symlink` (default), file-only `hardlink`, and `copy`.
Symlinks point directly to the physical winning source; no rendered trees or
templates exist. `apply` skips conflicts unless explicitly forced.

## Importing an existing file

`dots devour <path>` safely brings one existing, unmanaged file or directory
from `$HOME` into the repository and immediately deploys it with the normal
strategy. The path is always `$HOME`-relative:

```bash
dots devour .config/foo/config
```

To import into the overlay selected by a selector name, use `--overlay`. This
uses the selector's normalized current value, rather than accepting a machine
specific overlay name directly:

```bash
dots devour .config/foo/config --overlay host
```

`devour` refuses already managed paths, repository destinations that already
exist, symlinks, and paths within atomic managed directories. A devoured
directory is added to `dots.toml` as an atomic deployment unit; its contents
are not managed individually.

> The repository mirrors `$HOME`. Files are symlinked by default.
> `dots.toml` describes exceptions. Selectors activate sparse overlays for
> machine-specific differences.
