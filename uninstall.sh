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

# Stop only this widget's Conky. `pkill -x conky` would take down every other
# Conky widget on the machine, so the process is identified by its config path.
# This also works when $DEST is already gone — the common reason to run this.
CONF="$(readlink -f "$DEST" 2>/dev/null)/conky.conf"

kill_vedetta() {          # $1 = signal
  local p cmd
  for p in $(pgrep -x conky 2>/dev/null); do
    cmd=$(tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null) || continue
    case $cmd in
      *"$CONF"*|*/vedetta/conky.conf*) kill "-$1" "$p" 2>/dev/null ;;
    esac
  done
}

kill_vedetta 15
sleep 0.5
kill_vedetta 9 || true

# only the symlink is removed; a real directory is left alone on purpose
[[ -L $DEST ]] && rm -f "$DEST"
rm -rf "${XDG_CACHE_HOME:-$HOME/.cache}/vedetta"

echo "vedetta removed (repository untouched)."
echo "State was at $DEST/state.lua — delete the repo to remove it."
echo "To drop Conky as well:  sudo apt-get remove --purge conky-std"
