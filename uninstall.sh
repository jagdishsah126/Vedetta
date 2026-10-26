#!/usr/bin/env bash
# ============================================================================
#  vedetta :: uninstaller  (no sudo required)
#  Removes the symlink, autostart entry, watcher service and caches.
#  The repository itself is never touched.
# ============================================================================
set -u
DEST="$HOME/.config/conky/vedetta"

systemctl --user disable --now vedetta-watch.service 2>/dev/null
rm -f "$HOME/.config/systemd/user/vedetta-watch.service"
systemctl --user daemon-reload 2>/dev/null

rm -f "$HOME/.config/autostart/vedetta.desktop"
"$DEST/bin/vedetta" stop 2>/dev/null || pkill -x conky 2>/dev/null

# only the symlink is removed; a real directory is left alone on purpose
[[ -L $DEST ]] && rm -f "$DEST"
rm -rf "${XDG_CACHE_HOME:-$HOME/.cache}/vedetta"

echo "vedetta removed (repository untouched)."
echo "State was at $DEST/state.lua — delete the repo to remove it."
echo "To drop Conky as well:  sudo apt-get remove --purge conky-std"
