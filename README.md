# claude-codex-termux

A simple shell script which downloads Claude Code and Codex CLI binaries from their official sources and patches them to run in a Termux environment.
Supports both a interactive menu and CLI arguments-based interface.
Note that only aarch64 devices are supported.

# get started

simplest way (interactive):

```sh
bash claude-codex-termux.sh
```

non-interactive (CLI arguments):

```sh
# install both (default)
bash claude-codex-termux.sh install both

# install only one
bash claude-codex-termux.sh install claude
bash claude-codex-termux.sh install codex

# uninstall
bash claude-codex-termux.sh uninstall both
bash claude-codex-termux.sh uninstall claude
bash claude-codex-termux.sh uninstall codex
```

# environment variables

- `FORCE_INSTALL_CC_CODEX=1`: reinstall even if the version marker already matches the latest upstream version
- `CODEX_RELEASE_TAG=vX.Y.Z`: pin a specific Codex release tag instead of resolving `latest` from GitHub

# what the script does

- Downloads the latest musl libc from Alpine's aarch64 repo and the latest Claude Code binary from `downloads.claude.ai`
- Downloads the latest Codex CLI release from GitHub (`openai/codex`)
- Patches each binary's hardcoded `/etc/resolv.conf` string to `/proc/self/fd/9\0`.
- Generates the resolver file from Android's `net.dns*` system properties, falling back to `1.1.1.1` / `8.8.8.8`
- Installs binaries to `~/.local/lib/{musl-claude,codex}` and wrappers to `~/.local/bin/{claude,codex}`
- Appends a guarded `PATH` block to `~/.bashrc`, `~/.zshrc`, and `~/.config/fish/config.fish`
