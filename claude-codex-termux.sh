#!/bin/bash
set -euo pipefail

section() { printf '\n=== %s ===\n' "$1"; }
step()    { printf '[%s] %s\n' "$1" "$2"; }
err()     { printf 'Error: %s\n' "$1" >&2; }

PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
USER_BIN="$HOME/.local/bin"
USER_LIB="$HOME/.local/lib"

MUSL_DIR="$USER_LIB/musl-claude"
CLAUDE_BIN="$MUSL_DIR/claude"
CLAUDE_VERSION_MARKER="$MUSL_DIR/.installed-version"
CLAUDE_RESOLV_CONF="$HOME/.config/claude/resolv.conf"

CODEX_DIR="$USER_LIB/codex"
CODEX_BIN="$CODEX_DIR/codex"
CODEX_VERSION_MARKER="$CODEX_DIR/.installed-version"
CODEX_RESOLV_CONF="$HOME/.config/codex/resolv.conf"

CURL=(curl -fsSL --retry 3 --retry-delay 2)

if [ $# -eq 0 ]; then
    printf '\nAction\n  1. Install\n  2. Uninstall\n\n'
    read -rp "Choice [1]: " raw_action
    raw_action="${raw_action:-1}"

    printf '\nTarget\n  1. Both\n  2. Claude Code\n  3. Codex CLI\n\n'
    read -rp "Choice [1]: " raw_target
    raw_target="${raw_target:-1}"
else
    raw_action="$1"
    raw_target="${2:-both}"
fi

case "$raw_action" in
    1|install)   action=install ;;
    2|uninstall) action=uninstall ;;
    *) err "Invalid action: $raw_action"; exit 1 ;;
esac

case "$raw_target" in
    1|both)   DO_CLAUDE=1; DO_CODEX=1 ;;
    2|claude) DO_CLAUDE=1; DO_CODEX=0 ;;
    3|codex)  DO_CLAUDE=0; DO_CODEX=1 ;;
    *) err "Invalid target: $raw_target"; exit 1 ;;
esac

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

if [ "$action" = "install" ]; then
    step "0/1" "Checking prerequisites..."
    MISSING=()
    command -v curl >/dev/null 2>&1 || MISSING+=(curl)
    command -v rg   >/dev/null 2>&1 || MISSING+=(ripgrep)
    [ -f "$PREFIX/etc/tls/cert.pem" ] || MISSING+=(ca-certificates)

    if [ ${#MISSING[@]} -gt 0 ]; then
        echo "    Installing: ${MISSING[*]}"
        pkg install -y "${MISSING[@]}" >/dev/null 2>&1 || {
            err "failed to install prerequisites. Run manually:"
            echo "  pkg install ${MISSING[*]}" >&2
            exit 1
        }
    else
        echo "    All prerequisites present."
    fi
fi

write_resolver_file() {
    local output_file="$1"
    mkdir -p "$(dirname "$output_file")"
    {
        found=0
        for prop in net.dns1 net.dns2 net.dns3 net.dns4; do
            val=$(getprop "$prop" 2>/dev/null | tr -d '\r')
            if [ -n "$val" ] && echo "$val" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$|:'; then
                echo "nameserver $val"
                found=1
            fi
        done
        if [ "$found" = "0" ]; then
            echo "nameserver 1.1.1.1"
            echo "nameserver 8.8.8.8"
        fi
    } > "$output_file"
}

# Replace "/etc/resolv.conf" with "/proc/self/fd/9\0" inside a binary
# both are 16 bytes so file layout is preserved.
patch_resolv_conf_binary() {
    local file="$1" off count=0
    local offs
    offs=$(grep -abo "/etc/resolv.conf" "$file" | cut -d: -f1 || true)
    if [ -z "$offs" ]; then
        if grep -aq "/proc/self/fd/9" "$file"; then
            echo "    already patched"
            return
        fi
        err "/etc/resolv.conf not found in binary"
        exit 1
    fi
    for off in $offs; do
        printf '/proc/self/fd/9\0' | dd of="$file" bs=1 seek="$off" count=16 conv=notrunc status=none
        count=$((count + 1))
    done
    echo "    patched $count occurrence(s)"
}

install_claude() {
    section "Claude Code"

    step "claude 1/4" "Finding latest musl version from Alpine..."
    INDEX=$("${CURL[@]}" "https://dl-cdn.alpinelinux.org/alpine/latest-stable/main/aarch64/")
    MUSL_APK=$(echo "$INDEX" | grep -o 'musl-[0-9][^"]*\.apk' | grep -v 'musl-dev\|musl-dbg' | sort -V | tail -1)
    [ -n "$MUSL_APK" ] || { err "Could not find musl apk in Alpine index"; exit 1; }
    echo "    Found: $MUSL_APK"

    step "claude 2/4" "Resolving latest Claude Code version..."
    VERSION=$("${CURL[@]}" "https://downloads.claude.ai/claude-code-releases/latest")
    [ -n "$VERSION" ] || { err "Could not resolve latest Claude Code version"; exit 1; }
    echo "    Version: $VERSION"

    INSTALL_TAG="$MUSL_APK|$VERSION"
    if [ "${FORCE_INSTALL_CC_CODEX:-0}" != "1" ] && [ -f "$CLAUDE_VERSION_MARKER" ] && [ "$(cat "$CLAUDE_VERSION_MARKER")" = "$INSTALL_TAG" ] && [ -x "$CLAUDE_BIN" ]; then
        step "claude 3/4" "Already up to date, skipping download."
    else
        rm -rf "$MUSL_DIR"
        rm -f "$USER_BIN/claude"
        mkdir -p "$MUSL_DIR"
        step "claude 3/4" "Downloading musl + Claude Code..."
        "${CURL[@]}" "https://dl-cdn.alpinelinux.org/alpine/latest-stable/main/aarch64/$MUSL_APK" -o "$TMP_DIR/musl.apk"
        tar --warning=no-unknown-keyword -xf "$TMP_DIR/musl.apk" -C "$MUSL_DIR"
        "${CURL[@]}" "https://downloads.claude.ai/claude-code-releases/$VERSION/linux-arm64-musl/claude" -o "$CLAUDE_BIN"
        chmod +x "$CLAUDE_BIN"
        sha256sum "$CLAUDE_BIN" | awk '{print "    claude sha256: "$1}'
    fi

    MUSL_LD="$MUSL_DIR/lib/libc.musl-aarch64.so.1"
    [ -f "$MUSL_LD" ] || { err "musl linker not found at $MUSL_LD"; exit 1; }

    step "claude 4/4" "Patching binaries + writing resolver/wrapper..."
    patch_resolv_conf_binary "$CLAUDE_BIN"
    patch_resolv_conf_binary "$MUSL_LD"
    write_resolver_file "$CLAUDE_RESOLV_CONF"

    mkdir -p "$USER_BIN"
    cat > "$USER_BIN/claude" <<WRAPPER
#!/usr/bin/env bash
# USE_BUILTIN_RIPGREP=0: bundled musl rg doesn't index correctly on Termux.
# LD_PRELOAD=: clear Termux preloads that conflict with the musl loader.
# FD 9: binary patched to read resolv.conf from /proc/self/fd/9.
TMPDIR="\${TMPDIR:-$PREFIX/tmp}"
CLAUDE_CODE_TMPDIR="\${CLAUDE_CODE_TMPDIR:-\$TMPDIR}"
CLAUDE_TMPDIR="\${CLAUDE_TMPDIR:-\$TMPDIR/claude}"
CLAUDE_RESOLV_CONF="\${CLAUDE_RESOLV_CONF:-$CLAUDE_RESOLV_CONF}"
if [ ! -f "\$CLAUDE_RESOLV_CONF" ]; then
    printf '%s\n' "Claude resolver file not found: \$CLAUDE_RESOLV_CONF" >&2
    exit 1
fi
exec env USE_BUILTIN_RIPGREP=0 DISABLE_AUTOUPDATER=1 LD_PRELOAD= \\
    TMPDIR="\$TMPDIR" CLAUDE_CODE_TMPDIR="\$CLAUDE_CODE_TMPDIR" CLAUDE_TMPDIR="\$CLAUDE_TMPDIR" \\
    "$MUSL_LD" "$CLAUDE_BIN" "\$@" \\
    9<"\$CLAUDE_RESOLV_CONF"
WRAPPER
    chmod +x "$USER_BIN/claude"

    echo "$INSTALL_TAG" > "$CLAUDE_VERSION_MARKER"
}

install_codex() {
    section "Codex CLI"

    step "codex 1/4" "Resolving Codex release from GitHub..."
    if [ -n "${CODEX_RELEASE_TAG:-}" ]; then
        TAG="$CODEX_RELEASE_TAG"
        echo "    Using tag override: $TAG"
    else
        META=$("${CURL[@]}" "https://api.github.com/repos/openai/codex/releases/latest")
        TAG=$(echo "$META" | grep -o '"tag_name":[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"\([^"]*\)"$/\1/')
    fi
    [ -n "$TAG" ] || { err "Could not resolve Codex release tag"; exit 1; }
    ASSET="codex-aarch64-unknown-linux-musl.tar.gz"
    TARBALL="https://github.com/openai/codex/releases/download/$TAG/$ASSET"
    echo "    Tag: $TAG"

    INSTALL_TAG="$TAG"
    if [ "${FORCE_INSTALL_CC_CODEX:-0}" != "1" ] && [ -f "$CODEX_VERSION_MARKER" ] && [ "$(cat "$CODEX_VERSION_MARKER")" = "$INSTALL_TAG" ] && [ -x "$CODEX_BIN" ]; then
        step "codex 2/4" "Already up to date, skipping download."
    else
        step "codex 2/4" "Downloading codex tarball..."
        rm -rf "$CODEX_DIR"
        rm -f "$USER_BIN/codex"
        mkdir -p "$CODEX_DIR"
        "${CURL[@]}" "$TARBALL" -o "$TMP_DIR/codex.tgz"
        tar -xzf "$TMP_DIR/codex.tgz" -C "$TMP_DIR"

        BIN_PATH="$TMP_DIR/codex-aarch64-unknown-linux-musl"
        [ -f "$BIN_PATH" ] || { err "codex binary not found at $BIN_PATH after extracting $ASSET"; exit 1; }

        mv "$BIN_PATH" "$CODEX_BIN"
        chmod +x "$CODEX_BIN"

        step "codex 3/4" "Patching binary resolv.conf reference..."
        patch_resolv_conf_binary "$CODEX_BIN"
        sha256sum "$CODEX_BIN" | awk '{print "    codex sha256: "$1}'
    fi

    step "codex 4/4" "Writing resolver + wrapper..."
    write_resolver_file "$CODEX_RESOLV_CONF"
    mkdir -p "$USER_BIN"
    cat > "$USER_BIN/codex" <<WRAPPER
#!/usr/bin/env bash
# Termux/Android has no /etc/resolv.conf: binary patched to read FD 9 instead.
set -eu
CODEX_BIN="$CODEX_BIN"
CODEX_RESOLV_CONF="$CODEX_RESOLV_CONF"
if [ ! -f "\$CODEX_RESOLV_CONF" ]; then
    printf '%s\n' "Codex resolver file not found: \$CODEX_RESOLV_CONF" >&2
    exit 1
fi
export SSL_CERT_FILE="\${SSL_CERT_FILE:-$PREFIX/etc/tls/cert.pem}"
exec "\$CODEX_BIN" "\$@" 9<"\$CODEX_RESOLV_CONF"
WRAPPER
    chmod +x "$USER_BIN/codex"

    echo "$INSTALL_TAG" > "$CODEX_VERSION_MARKER"
}

PATH_MARKER_BEGIN="# >>> cc-termux PATH >>>"
PATH_MARKER_END="# <<< cc-termux PATH <<<"

add_path_to_rc() {
    local rc="$1" block="$2"
    if [ -f "$rc" ] && grep -qF "$PATH_MARKER_BEGIN" "$rc"; then
        echo "    $rc: already configured"
        return
    fi
    mkdir -p "$(dirname "$rc")"
    printf '\n%s\n' "$block" >> "$rc"
    echo "    $rc: added"
}

setup_shell_path() {
    section "Shell PATH"
    case ":${PATH:-}:" in
        *":$USER_BIN:"*) echo "    current session PATH already includes $USER_BIN" ;;
        *) echo "    current session PATH will include $USER_BIN after reloading your shell" ;;
    esac

    local sh_block fish_block
    sh_block="$PATH_MARKER_BEGIN
case \":\$PATH:\" in
    *\":\$HOME/.local/bin:\"*) ;;
    *) export PATH=\"\$HOME/.local/bin:\$PATH\" ;;
esac
$PATH_MARKER_END"

    fish_block="$PATH_MARKER_BEGIN
if not contains \"\$HOME/.local/bin\" \$PATH
    set -gx PATH \"\$HOME/.local/bin\" \$PATH
end
$PATH_MARKER_END"

    add_path_to_rc "$HOME/.bashrc" "$sh_block"
    add_path_to_rc "$HOME/.zshrc" "$sh_block"
    add_path_to_rc "$HOME/.config/fish/config.fish" "$fish_block"
}

uninstall_paths() {
    section "Uninstall $1"
    shift
    for p in "$@"; do
        [ -e "$p" ] || [ -L "$p" ] || continue
        rm -rf "$p"
        echo "    removed $p"
    done
}

if [ "$action" = "uninstall" ]; then
    [ "$DO_CLAUDE" = "1" ] && uninstall_paths "Claude Code" "$USER_BIN/claude" "$MUSL_DIR" "$CLAUDE_RESOLV_CONF"
    [ "$DO_CODEX" = "1" ]  && uninstall_paths "Codex CLI"   "$USER_BIN/codex"  "$CODEX_DIR" "$CODEX_RESOLV_CONF"
    printf '\nDone. Auth/config dirs (~/.claude, ~/.codex) and rc-file PATH entries\n'
    echo "left intact."
    exit 0
fi

[ "$DO_CLAUDE" = "1" ] && install_claude
[ "$DO_CODEX" = "1" ] && install_codex
setup_shell_path

printf '\nDone.\n'
case ":${PATH:-}:" in
    *":$USER_BIN:"*) ;;
    *)
        case "$(basename "${SHELL:-}")" in
            bash) echo "  (Open a new shell or: source ~/.bashrc)" ;;
            zsh)  echo "  (Open a new shell or: source ~/.zshrc)" ;;
            fish) echo "  (Open a new shell or: source ~/.config/fish/config.fish)" ;;
            *)    echo "  (Open a new shell to pick up the updated PATH)" ;;
        esac
        ;;
esac
[ "$DO_CLAUDE" = "1" ] && echo "  Run: claude"
[ "$DO_CODEX" = "1" ] && echo "  Run: codex"
