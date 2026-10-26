#!/usr/bin/env bash
# ============================================================================
#  vedetta :: installer  (no sudo required)
#  Links the widget into ~/.config/conky/vedetta, installs autostart and the
#  optional position-watcher user service, then starts it.
# ============================================================================
set -u

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="$HOME/.config/conky/vedetta"
AUTOSTART="$HOME/.config/autostart/vedetta.desktop"
UNIT="$HOME/.config/systemd/user/vedetta-watch.service"

say()  { printf '  %s\n' "$*"; }
section() { printf '\n\033[1m%s\033[0m\n' "$*"; }

section "1/5  checking prerequisites"
if ! command -v conky >/dev/null 2>&1; then
  echo "  ✗ conky is not installed. Run this once:" >&2
  echo "      sudo apt-get install -y --no-install-recommends conky-std" >&2
  exit 1
fi
say "✓ conky $(conky --version 2>/dev/null | head -1 | awk '{print $2}')"

for t in xdotool xrandr; do
  command -v "$t" >/dev/null 2>&1 && say "✓ $t" || say "! $t missing (drag-save disabled)"
done

section "2/5  linking config"
mkdir -p "$HOME/.config/conky"
if [[ -e $DEST && ! -L $DEST ]]; then
  mv "$DEST" "$DEST.bak.$(date +%s)"
  say "existing directory backed up"
fi
ln -sfn "$SRC" "$DEST"
chmod +x "$SRC/bin/collect.sh" "$SRC/bin/vedetta" "$SRC/install.sh" "$SRC/uninstall.sh"
# runtime state is never committed; seed it on first run
[[ -f $DEST/state.lua ]] || { cp "$DEST/state.lua.default" "$DEST/state.lua"; say "seeded state.lua"; }
say "✓ $DEST -> $SRC"

# clean up a pre-rename install if one is still around
for old in "sda-panel" "sda-panel.desktop"; do
  [[ -e "$HOME/.config/conky/$old" ]] && rm -f "$HOME/.config/conky/$old" && say "removed legacy $old"
  [[ -e "$HOME/.config/autostart/$old" ]] && rm -f "$HOME/.config/autostart/$old" && say "removed legacy $old"
done
if [[ -f "$HOME/.config/systemd/user/sda-panel-watch.service" ]]; then
  systemctl --user disable --now sda-panel-watch.service 2>/dev/null
  rm -f "$HOME/.config/systemd/user/sda-panel-watch.service"
  say "removed legacy watcher service"
fi

section "3/5  autostart entry"
mkdir -p "$(dirname "$AUTOSTART")"
cat > "$AUTOSTART" <<EOF
[Desktop Entry]
Type=Application
Version=1.0
Name=vedetta
Comment=Transparent desktop panel for disk, CPU, memory and thermal health
Exec=/bin/bash -c 'sleep 2; $DEST/bin/vedetta start'
Terminal=false
NoDisplay=true
X-GNOME-Autostart-enabled=true
OnlyShowIn=XFCE;
EOF
say "✓ $AUTOSTART"

section "4/5  position watcher (systemd --user)"
mkdir -p "$(dirname "$UNIT")"
cat > "$UNIT" <<EOF
[Unit]
Description=vedetta position watcher
PartOf=graphical-session.target

[Service]
Type=simple
Environment=DISPLAY=:0
Environment=XAUTHORITY=%h/.Xauthority
ExecStart=$DEST/bin/vedetta watch
Restart=always
RestartSec=5

[Install]
WantedBy=default.target
EOF
systemctl --user daemon-reload 2>/dev/null
systemctl --user enable --now vedetta-watch.service 2>/dev/null \
  && say "✓ watcher enabled" || say "! watcher not enabled (systemd --user unavailable)"

section "5/5  starting"
"$DEST/bin/vedetta" restart

cat <<EOF

Done.

  drag     : hold ALT + left-drag the widget
  resize   : $DEST/bin/vedetta size +     (or - , or 7..20)
  toggle   : $DEST/bin/vedetta toggle
  status   : $DEST/bin/vedetta status
  uninstall: $DEST/uninstall.sh
EOF
