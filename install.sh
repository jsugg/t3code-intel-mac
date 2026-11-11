#!/bin/bash
# Installs the t3 wrapper for Intel Macs: vp, a t3code checkout, the wrapper, and a first build.
#   curl -fsSL https://raw.githubusercontent.com/jsugg/t3code-intel-mac/main/install.sh | bash
# Env: T3_REPO (checkout path), T3_CHANNEL (stable|nightly|main), T3_BIN_DIR, T3_INTEL_FORCE=1.
set -euo pipefail

WRAPPER_URL="https://raw.githubusercontent.com/jsugg/t3code-intel-mac/main/bin/t3"
UPSTREAM_URL="${T3_UPSTREAM_URL:-https://github.com/pingdotgg/t3code}"
CONFIG_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/t3code-intel-mac/config"
DEFAULT_REPO="${XDG_DATA_HOME:-$HOME/.local/share}/t3code-intel-mac/t3code"
T3_REPO="${T3_REPO:-$DEFAULT_REPO}"
T3_CHANNEL="${T3_CHANNEL:-stable}"
BIN_DIR="${T3_BIN_DIR:-$HOME/.local/bin}"
DEST="$BIN_DIR/t3"

die() { echo "install: $*" >&2; exit 1; }
say() { echo "install: $*" >&2; }

if [ "$(uname -s)-$(uname -m)" != Darwin-x86_64 ] && [ "${T3_INTEL_FORCE:-0}" != 1 ]; then
  die "this is for Intel Macs. Elsewhere use the official CLI: curl -fsSL https://t3.codes/install.sh | sh (set T3_INTEL_FORCE=1 to continue anyway)"
fi
case "$T3_CHANNEL" in stable | nightly | main) ;; *) die "T3_CHANNEL must be stable, nightly, or main" ;; esac
for tool in git curl; do command -v "$tool" >/dev/null || die "$tool is required"; done

if [ -e "$DEST" ] && ! grep -q 't3code-intel-mac' "$DEST" 2>/dev/null; then
  die "$DEST exists and is not this wrapper; remove it or set T3_BIN_DIR"
fi

load_vp() {
  local env_file
  for env_file in "${XDG_CONFIG_HOME:-$HOME/.config}/vite-plus/env" "$HOME/.vite-plus/env"; do
    # shellcheck disable=SC1090
    [ -f "$env_file" ] && . "$env_file" >/dev/null 2>&1 || true
  done
  command -v vp >/dev/null
}

if ! command -v vp >/dev/null && ! load_vp; then
  # Keep vp from taking over the global node; the wrapper asks it for the pinned version.
  say "installing vp (Vite+)"
  curl -fsSL https://vite.plus | VP_NODE_MANAGER=no CI=1 bash
  load_vp || die "vp installed but not found; open a new shell and rerun"
fi

if [ -d "$T3_REPO/.git" ]; then
  say "using existing checkout at $T3_REPO"
else
  [ -e "$T3_REPO" ] && die "$T3_REPO exists but is not a git checkout"
  say "cloning $UPSTREAM_URL into $T3_REPO"
  mkdir -p "$(dirname "$T3_REPO")"
  git clone -q --filter=blob:none "$UPSTREAM_URL" "$T3_REPO"
fi

mkdir -p "$BIN_DIR"
# From a clone, install that clone's wrapper; piped through bash, download it.
src=""
if [ -f "${BASH_SOURCE[0]:-}" ]; then
  src="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/bin/t3"
fi
tmp="$(mktemp "$DEST.XXXXXX")"
trap 'rm -f "$tmp"' EXIT
if [ -n "$src" ] && [ -f "$src" ]; then
  cp "$src" "$tmp"
else
  curl -fsSL "$WRAPPER_URL" -o "$tmp" || die "could not download $WRAPPER_URL"
fi
bash -n "$tmp" || die "wrapper does not parse"
chmod +x "$tmp"
mv "$tmp" "$DEST"
trap - EXIT
say "installed $DEST"

if [ "$T3_REPO" != "$DEFAULT_REPO" ]; then
  mkdir -p "$(dirname "$CONFIG_FILE")"
  printf 'T3_REPO=%s\n' "$T3_REPO" >"$CONFIG_FILE"
  say "wrote $CONFIG_FILE"
fi

T3_REPO="$T3_REPO" "$DEST" update --channel "$T3_CHANNEL" --yes

case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) say "add $BIN_DIR to PATH, e.g.: echo 'export PATH=\"$BIN_DIR:\$PATH\"' >> ~/.zshrc" ;;
esac
say "done. Run 't3' in a project folder, or 't3 wrapper' for the extra commands."
