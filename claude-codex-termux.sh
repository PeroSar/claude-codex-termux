#!/bin/bash
set -euo pipefail

section() { printf '\n=== %s ===\n' "$1"; }
step()    { printf '[%s] %s\n' "$1" "$2"; }
err()     { printf 'Error: %s\n' "$1" >&2; }

PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
USER_BIN="$HOME/.local/bin"
USER_LIB="$HOME/.local/lib"

CLAUDE_PKG_DIR="$USER_LIB/claude-code"
CLAUDE_CLI="$CLAUDE_PKG_DIR/cli.js"
CLAUDE_VERSION_MARKER="$CLAUDE_PKG_DIR/.installed-version"

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
    command -v curl    >/dev/null 2>&1 || MISSING+=(curl)
    command -v rg      >/dev/null 2>&1 || MISSING+=(ripgrep)
    command -v python3 >/dev/null 2>&1 || MISSING+=(python)
    command -v node    >/dev/null 2>&1 || MISSING+=(nodejs)
    command -v objcopy >/dev/null 2>&1 || MISSING+=(binutils)
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

    step "claude 1/4" "Resolving latest Claude Code version..."
    VERSION=$("${CURL[@]}" "https://downloads.claude.ai/claude-code-releases/latest")
    [ -n "$VERSION" ] || { err "Could not resolve latest Claude Code version"; exit 1; }
    echo "    Version: $VERSION"

    MANIFEST_URL="https://downloads.claude.ai/claude-code-releases/$VERSION/manifest.json"
    BIN_URL="https://downloads.claude.ai/claude-code-releases/$VERSION/linux-arm64/claude"
    CHECKSUM=$("${CURL[@]}" "$MANIFEST_URL" \
        | python3 -c "import json,sys; print(json.load(sys.stdin)['platforms']['linux-arm64']['checksum'])")
    [ -n "$CHECKSUM" ] || { err "Could not resolve checksum from manifest"; exit 1; }

    INSTALL_TAG="$VERSION|$CHECKSUM"
    if [ "${FORCE_INSTALL_CC_CODEX:-0}" != "1" ] \
        && [ -f "$CLAUDE_VERSION_MARKER" ] \
        && [ "$(cat "$CLAUDE_VERSION_MARKER")" = "$INSTALL_TAG" ] \
        && [ -x "$CLAUDE_CLI" ]; then
        step "claude 2/4" "Already up to date, skipping."
    else
        step "claude 2/4" "Downloading bun-packaged linux-arm64 binary..."
        rm -rf "$CLAUDE_PKG_DIR"
        rm -f "$USER_BIN/claude"
        mkdir -p "$CLAUDE_PKG_DIR"
        "${CURL[@]}" "$BIN_URL" -o "$TMP_DIR/claude-bin"
        echo "$CHECKSUM  $TMP_DIR/claude-bin" | sha256sum -c - >/dev/null
        echo "    checksum OK: $CHECKSUM"

        step "claude 3/4" "Extracting .bun section and patching cli.js..."
        objcopy -O binary --only-section=.bun "$TMP_DIR/claude-bin" "$TMP_DIR/bun.section"
        python3 - "$TMP_DIR/bun.section" "$CLAUDE_CLI" <<'EXTRACT'
import re, struct, sys
section_path, out_path = sys.argv[1], sys.argv[2]
with open(section_path, 'rb') as f:
    data = f.read()

marker = b'file:///$bunfs/root/src/entrypoints/cli.js'
i = data.find(marker)
if i < 0:
    sys.exit('cli.js marker not found in .bun section')
start = data.find(b'// @bun', i)
if start < 0:
    sys.exit('bundle start not found after entrypoint marker')
size = struct.unpack('<I', data[start - 4:start])[0]
src = data[start:start + size].decode('utf-8')

head = '// @bun @bytecode @bun-cjs\n(function(exports, require, module, __filename, __dirname) {'
tail = '})\n'
if not src.startswith(head) or not src.endswith(tail):
    sys.exit('unexpected CJS wrapper shape around cli.js')
body = src[len(head):-len(tail)]

SENTINEL = 'process.env.CLAUDE_TMPDIR||"/tmp/claude"'
BRIDGE_DONE = 'claude-mcp-browser-bridge-'
BRIDGE_DONE_MARKER = 'process.env.CLAUDE_CODE_TMPDIR||process.env.TMPDIR||"/tmp"'

# Patch 1: sandbox tmp allowlist (literal match)
frm1 = '"/tmp/claude","/private/tmp/claude"'
to1 = ('(process.env.CLAUDE_TMPDIR||"/tmp/claude"),'
       '(process.env.CLAUDE_TMPDIR||"/private/tmp/claude")')
n1 = body.count(frm1)
if n1 == 0:
    if SENTINEL in body:
        print('    already patched: sandbox tmp allowlist')
    else:
        sys.exit(f'patch target not found: {frm1}')
elif n1 > 1:
    sys.exit(f'patch 1 matched {n1} times')
else:
    body = body.replace(frm1, to1)
    print('    patched: sandbox tmp allowlist')

# Patch 2: browser bridge tmpdir (regex — function name is minified, varies per build)
pat2 = re.compile(r'`/tmp/claude-mcp-browser-bridge-\$\{([A-Za-z_$][\w$]*)\(\)\}`')
matches = pat2.findall(body)
if not matches:
    if BRIDGE_DONE in body and BRIDGE_DONE_MARKER in body:
        print('    already patched: browser bridge tmpdir')
    else:
        sys.exit('patch target not found: /tmp/claude-mcp-browser-bridge-${<fn>()}')
elif len(set(matches)) > 1:
    sys.exit(f'browser-bridge fn name ambiguous: {sorted(set(matches))}')
elif len(matches) > 1:
    sys.exit(f'browser-bridge pattern matched {len(matches)} times')
else:
    fn = matches[0]
    body = pat2.sub(
        '`${process.env.CLAUDE_CODE_TMPDIR||process.env.TMPDIR||"/tmp"}'
        '/claude-mcp-browser-bridge-${' + fn + '()}`',
        body,
    )
    print(f'    patched: browser bridge tmpdir (fn={fn})')

out = '#!/usr/bin/env node\n/* __CLAUDE_TERMUX_RUNTIME_PATCHED__ */\n' + body
with open(out_path, 'w') as f:
    f.write(out)
print(f'    wrote {out_path} ({len(out)} bytes)')
EXTRACT
        chmod +x "$CLAUDE_CLI"
        sha256sum "$CLAUDE_CLI" | awk '{print "    cli.js sha256: "$1}'

        # Bun resolves these as built-ins at runtime; Node needs real packages
        # installed as siblings of cli.js. node-fetch pinned to v2 (v3 is ESM
        # and the bundle uses CJS require).
        cat > "$CLAUDE_PKG_DIR/package.json" <<'PKG'
{
  "name": "claude-code-termux-runtime",
  "version": "0.0.0",
  "private": true,
  "dependencies": {
    "ajv": "^8",
    "ajv-formats": "^3",
    "node-fetch": "^2",
    "undici": "^6",
    "ws": "^8",
    "yaml": "^2"
  }
}
PKG
        echo "    Installing runtime shims (ws, undici, yaml, ajv, ajv-formats, node-fetch)..."
        (cd "$CLAUDE_PKG_DIR" && npm install --omit=dev --no-audit --no-fund --loglevel=error)
    fi

    step "claude 4/4" "Writing wrapper..."
    mkdir -p "$USER_BIN"
    cat > "$USER_BIN/claude" <<WRAPPER
#!/usr/bin/env bash
# USE_BUILTIN_RIPGREP=0: bundled rg vendor path isn't shipped with the
# extracted cli.js, so defer to the Termux pkg \`rg\` on PATH.
# CLAUDE_*TMPDIR: the cli.js is patched to honor these; Termux has no
# writable /tmp in app context, so anchor them under \$PREFIX/tmp.
TMPDIR="\${TMPDIR:-$PREFIX/tmp}"
CLAUDE_CODE_TMPDIR="\${CLAUDE_CODE_TMPDIR:-\$TMPDIR}"
CLAUDE_TMPDIR="\${CLAUDE_TMPDIR:-\$TMPDIR/claude}"
mkdir -p "\$CLAUDE_TMPDIR"
CA_BUNDLE="\${SSL_CERT_FILE:-$PREFIX/etc/tls/cert.pem}"
# SSL_CERT_DIR: Bun's bundled OpenSSL probes a compiled-in certs/ dir that
# Termux doesn't ship; point it at an existing (cert-free) dir to silence the
# "Cannot open directory" warning. Real trust anchors come from SSL_CERT_FILE.
CA_DIR="\${SSL_CERT_DIR:-$PREFIX/etc/tls}"
exec env USE_BUILTIN_RIPGREP=0 DISABLE_AUTOUPDATER=1 \\
    TMPDIR="\$TMPDIR" CLAUDE_CODE_TMPDIR="\$CLAUDE_CODE_TMPDIR" CLAUDE_TMPDIR="\$CLAUDE_TMPDIR" \\
    SSL_CERT_FILE="\$CA_BUNDLE" NODE_EXTRA_CA_CERTS="\$CA_BUNDLE" SSL_CERT_DIR="\$CA_DIR" \\
    node "$CLAUDE_CLI" "\$@"
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
    [ "$DO_CLAUDE" = "1" ] && uninstall_paths "Claude Code" \
        "$USER_BIN/claude" "$CLAUDE_PKG_DIR" \
        "$USER_LIB/glibc-claude" "$USER_LIB/musl-claude" "$USER_LIB/claude-code" \
        "$HOME/.config/claude/resolv.conf" \
        "$HOME/.config/claude/nsswitch.conf" \
        "$HOME/.config/claude/hosts"
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
