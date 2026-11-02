#!/usr/bin/env bash
# ============================================================================
#  vedetta :: deploy
#  Copies the repository to the runtime location and restarts the widget.
#
#    ./deploy.sh                 deploy to the default target
#    ./deploy.sh /some/dir       deploy somewhere else
#    ./deploy.sh --install       deploy, then make that copy the active install
#
#  state.lua is never copied: the live position, size and tint are the
#  deployment's own data and must survive every deploy.
# ============================================================================
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="${VEDETTA_DEPLOY_DIR:-$HOME/Desktop/System Files/Vedetta}"
INSTALL=0

say() { printf '  %s\n' "$*"; }

for arg in "$@"; do
  case $arg in
    --install) INSTALL=1 ;;
    -h|--help) awk 'NR>=3 && NR<=11 { sub(/^#[[:space:]]*/, ""); print }' "${BASH_SOURCE[0]}"; exit 0 ;;
    -*) echo "unknown option: $arg" >&2; exit 2 ;;
    *)  TARGET=$arg ;;
  esac
done

[[ -d $SRC ]] || { echo "source missing: $SRC" >&2; exit 1; }
[[ $(readlink -f "$SRC") != "$(readlink -f "$TARGET" 2>/dev/null || echo x)" ]] \
  || { echo "refusing to deploy onto itself" >&2; exit 1; }
command -v rsync >/dev/null 2>&1 || { echo "rsync is required" >&2; exit 1; }

echo
echo "deploying"
say "from  $SRC"
say "to    $TARGET"
mkdir -p "$TARGET"

rsync -ai --delete \
  --exclude='/.git' \
  --exclude='/.gitignore' \
  --exclude='/.gitattributes' \
  --exclude='/state.lua' \
  --exclude='/*.jpg' --exclude='/*.jpeg' --exclude='/*.png' \
  "$SRC"/ "$TARGET"/

chmod +x "$TARGET/bin/vedetta" "$TARGET/bin/collect.sh" \
         "$TARGET/install.sh" "$TARGET/uninstall.sh" "$TARGET/deploy.sh"
[[ -f $TARGET/state.lua ]] || { cp "$TARGET/state.lua.default" "$TARGET/state.lua"; say "seeded state.lua"; }

echo
if (( INSTALL )); then
  "$TARGET/install.sh"
elif [[ $(readlink -f "$HOME/.config/conky/vedetta" 2>/dev/null || true) == "$TARGET" ]]; then
  say "active install — restarting"
  "$TARGET/bin/vedetta" restart
else
  say "not the active install"
  say "run: $TARGET/install.sh   (or ./deploy.sh --install)"
fi
