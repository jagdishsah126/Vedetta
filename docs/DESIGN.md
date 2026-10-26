# Design notes

Why Vedetta is built the way it is. This is the reasoning behind the code, not a
manual — see [the README](../README.md) for installation and usage.

---

## 1. Goal

A small, translucent panel on the desktop that answers one question at a glance:
**how much room is left, and is the machine healthy?**

Priority order:

1. **Disk** — every partition of one physical disk, whether mounted or not, with
   used / free / **reserved** space. This is the part no off-the-shelf widget gets
   right.
2. **CPU** — per-thread usage, average, frequency, load.
3. **Memory** — RAM and swap.
4. **PC health** — temperatures, fan, battery.
5. **Network** — cheap to add, easy to remove.

Explicit non-goals: a web UI, a daemon, remote monitoring, historical graphs or a
database, alerting, multi-host support, and any runtime network traffic.

---

## 2. Engine

The whole project rests on one decision: **use an existing renderer and write zero
engine code.**

| Candidate | Verdict |
|---|---|
| **Conky** | Chosen. Native X11 transparency, ~1 MB installed, config-only, starts with the session, built for exactly this |
| Glances | Python + browser UI — the wrong shape and too heavy for a small machine |
| Netdata | Daemon + agent, hundreds of MB, far out of scope |
| btop / bottom | Terminal UI — no transparency, no desktop placement |
| Custom GTK/PyGObject | Possible, but that is re-implementing the engine |
| Cysboard | Unmaintained since 2017 |

What is authored here: **one Conky config** and **one Bash collector**. No
frameworks, no Lua renderer, no compiled code.

---

## 3. Architecture

```
/proc · /sys · lsblk · df
          │
          ▼
    bin/collect.sh          ← all logic; runs standalone for debugging
      ├─ lsblk -b -P        → partition list, sizes, filesystem types
      ├─ /proc/self/mounts  → mounted / unmounted per device
      ├─ df -B1             → used, available → reserved
      ├─ /proc/stat delta   → CPU usage per thread
      ├─ /proc/meminfo      → RAM and swap
      ├─ hwmon, BAT*        → temperatures, fan, battery
      └─ /sys/class/net + cached samples → network rates
          │  prints Conky markup on stdout
          ▼
      conky.conf  ──${execpi 2}──►  the panel
          │
          └── autostart + position watcher (systemd --user)
```

**Design rules**

- **One data source.** Everything on screen is reproducible by running
  `bash ~/.config/conky/vedetta/bin/collect.sh` in a terminal. If the panel looks
  wrong, that command shows the exact text Conky received.
- **Text, not widgets.** Conky's `$bar`, `$graph` and Lua renderers are avoided.
  Gauges are Unicode block glyphs in two colours. Output stays a plain monospace
  table that survives Conky version drift and can be diffed.
- **No root, ever.** Every reading comes from world-readable `/proc` and `/sys`, or
  from `df`/`lsblk` on paths the user already owns.
- **No subprocess in the hot path** where it can be avoided — `printf` and shell
  builtins do the formatting.

---

## 4. The disk model

This is the reason the project exists.

### 4.1 Unmounted partitions

Conky's built-in `${fs_used}` and friends operate on **mount points**. Unmount a
partition and it vanishes from the widget — exactly when you might want to know its
size. So the collector joins two sources:

| Source | Provides |
|---|---|
| `lsblk -b -P -o NAME,SIZE,FSTYPE,MOUNTPOINT,TYPE` | every partition that exists, mounted or not |
| `df -B1 --output=source,size,used,avail,target` | the numbers, for filesystems that are mounted |

A device found by `lsblk` but absent from `df` is rendered
`○ unmounted` with its size and `—` for used/free. A device that disappears from
both (disk unplugged) is not invented; the row simply goes away on the next refresh.

### 4.2 Mapping a filesystem back to its partition

`df` reports the path the filesystem was mounted from. For an ordinary partition that
is `/dev/sda2`; for LUKS, LVM or RAID it is `/dev/mapper/...`, which is **not** a
partition on the disk. Matching only the literal device name would therefore mark a
perfectly busy encrypted partition as unmounted.

Resolution is two-step, and the common case costs nothing:

1. `/dev/sdaN` → `sdaN`, if that name is in the `lsblk` partition list.
2. otherwise `lsblk -lsn -o NAME <source>` walks up the parent chain and the first
   name that *is* one of our partitions wins.

`-l` matters: without it `lsblk -s` prints tree glyphs (`└─sda6`) that would never
match. Sources that are not on this disk (`tmpfs`, `overlay`, another disk) fail both
steps and are ignored. When several mounts share one device (Btrfs subvolumes) the
first one is used, which keeps the panel stable across refreshes.

### 4.3 Reserved space

ext4 keeps 5 % of the filesystem out of reach of unprivileged writers. `df` shows
it only implicitly — the gap between *free* and *available*:

```
reserved = fs_size − used − available
```

This is exact for ext4 and needs **no root** (the authoritative number lives in
`tune2fs -l`, which does). NTFS and vfat have no equivalent reserve, so the column
correctly reads `0B` there rather than lying with a percentage.

### 4.4 Gauge ratios

A partition's gauge is `used / (used + available)` — *how full is it for me* — which
deliberately excludes the root reserve. That matches what the user can actually
write, and matches `df`'s `Use%`.

`used + available` rather than `size` also keeps the maths correct on filesystems
where metadata eats a few percent.

### 4.5 Totals

The disk summary sums whatever partitions `lsblk` reports and subtracts the sum from
the disk size, giving the unallocated tail. It is derived, never hard-coded, so it
follows repartitioning automatically.

`disk` is the physical capacity, but `used` and `free` come from `df`, so they only
cover **mounted** filesystems. Presenting that partial sum as whole-disk usage would
be a quiet lie, so the panel counts mounted partitions and adds a qualifier row only
when the numbers are incomplete:

```
   238.5G disk  26.3G used  53.6G free
   3 of 5 mounted — used/free cover mounted only
```

---

## 5. Rendering

### 5.1 Monospace canvas

The layout is a fixed character grid, `COLS = 54`, formatted with `printf`. The window
width in `conky.conf` is computed from that constant and the font size:

```lua
local width = math.floor(54 * scale * 0.8031) + 22
```

Keeping the grid in characters (rather than pixels) means every column stays aligned
whatever font size the user picks, and the panel can be resized at runtime without a
relayout pass.

### 5.2 Gauges

A gauge is a fixed run of `▬` glyphs: `n` in the fill colour, the rest in a recessed
`C_TRACK` colour, so the empty portion reads as an empty track rather than as blank
space. No `$bar`, no per-frame widget state.

### 5.3 Colour and thresholds

A single warn/critical threshold pair per metric drives the colour:

```bash
TH_CPU_W=60; TH_CPU_C=85     # percent
TH_RAM_W=70; TH_RAM_C=88
TH_TMP_W=70; TH_TMP_C=85     # degrees C
TH_DSK_W=75; TH_DSK_C=90
```

Healthy readings stay dim and quiet; only approaching problems get colour. A panel
where everything is bright stops conveying anything.

---

## 6. Transparency and placement

### 6.1 Why the tint is not at 8 %

The original request was near-total transparency. On a real wallpaper with light
regions, dim grey text at 8 % is unreadable. The default settled on **71 %**
(`own_window_argb_value = 183`), and it is adjustable at runtime
(`vedetta tint 0..100`), so the trade-off belongs to the user rather than the code.

**Conky quirk worth knowing:** `own_window_transparent` must be **false** for
`own_window_argb_value` to take effect. Setting it to true (the intuitive choice)
silently discards the tint. This is documented in the README's troubleshooting
section because it costs everyone an hour.

### 6.2 Placement

The panel lives on the right edge, because desktop icons are drawn on the same layer
and occupy the left. `gap_x` / `gap_y` are measured from the right and top edges, so
the widget keeps its visual position when the screen width changes.

### 6.3 Dragging and persistence

`own_window_type = 'normal'` with `undecorated, below, sticky, skip_taskbar,
skip_pager` allows XFCE's standard **Alt+drag** to move the window, while keeping it
under normal windows and out of the taskbar.

Persisting that position is the one thing a static config cannot do. A small
`systemd --user` service watches the window geometry and writes the offset to
`state.lua`:

- it polls X geometry, not the Conky process (whose rewritten `cmdline` makes
  `pgrep -f` unreliable);
- it applies a **16 px dead zone**, so the window manager's settle-in nudge after a
  restart is never stored as a user drag;
- writes are atomic (temp file + move), so a crash mid-write cannot corrupt state.

The service needs to know **which** X display to inspect, so the installer records the
`DISPLAY` it was run under rather than assuming `:0`, and only writes `XAUTHORITY`
when that file actually exists — pointing `xdotool` at a nonexistent authority file
fails silently. If `xdotool` or `xrandr` are missing the service is not installed at
all, and `vedetta watch` exits cleanly (with `Restart=on-failure`, so systemd does not
loop) rather than idling forever. Dragging still works in that mode; the position is
just not remembered.

---

## 7. Health readings without privileges

| Reading | Source | Root |
|---|---|---|
| Package / per-core temperature | `hwmon` driver named `coretemp` | no |
| Any vendor temperature | first `hwmon` exposing `temp1_input` | no |
| Fan RPM | first `hwmon` exposing a `fan*_input` | no |
| Battery level / status / voltage | `/sys/class/power_supply/BAT*` | no |
| CPU frequency | `cpufreq/scaling_cur_freq` | no |
| Load, uptime | `/proc/loadavg`, `/proc/uptime` | no |
| SSD SMART health | `smartctl` | **yes** |

SMART was deliberately left out: it is the only reading that needs elevation, and a
root-owned timer plus a world-readable snapshot is a lot of machinery for one line.
Any field the machine cannot supply (no fan, no battery, no sensors) is simply
omitted rather than printed as a plausible-looking zero.

**hwmon indices are not stable across reboots**, so drivers are resolved by reading
`/sys/class/hwmon/*/name` and never by a hard-coded `hwmonN` path.

---

## 8. Controller

`bin/vedetta` is a thin wrapper, not a service:

| Subcommand | Purpose |
|---|---|
| `start` / `stop` / `restart` / `toggle` | process control |
| `size [n\|+\|-]` | write `scale` to state, restart |
| `tint [0..100]` | write the ARGB value to state, restart |
| `save-pos` | snapshot window geometry into state |
| `watch` | the geometry watcher loop (run by systemd) |
| `status` | process, geometry, scale, tint, log tail |
| `test` | run the collector and print plain text |

Process discovery reads `/proc/*/cmdline` rather than using `pgrep -f`, because
Conky rewrites its own command line at startup and `-f` matching misses it. Stale
instances are killed by PID before starting a new one — two overlapping Conky
windows produce visible ghosting and was a real bug during development.

State lives in `state.lua`, a tiny Lua table read by `conky.conf`. It is runtime
data: machine-specific, regenerated by the installer, and **never committed**.

---

## 9. Testing

The collector is testable without touching real hardware:

```bash
VEDETTA_FAKE_UNMOUNT=sda3 bash bin/collect.sh
```

Multiple devices: `VEDETTA_FAKE_UNMOUNT=sda3,sda4`.

Checklist used during development:

- [ ] All partitions listed, each with mounted state, used, free, reserved
- [ ] Faking an unmount flips the row to `○ unmounted` within one refresh, no crash
- [ ] With anything unmounted, the `N of M mounted` qualifier appears and the totals
      are never presented as whole-disk usage
- [ ] Reserved matches `tune2fs` (block count × block size) on ext4, `0` on NTFS/vfat
- [ ] A filesystem mounted from `/dev/mapper/...` is attributed to its partition, not
      shown as unmounted
- [ ] Temperatures match `sensors` within ±1 °C at the same instant
- [ ] RAM matches `free -h`; swap matches `swapon --show`
- [ ] Idle cost under 1 % of one core and under 20 MB RSS
- [ ] Exactly one Conky process after repeated restarts
- [ ] Survives logout/login, and `vedetta stop` really stops it
- [ ] `uninstall.sh` stops only Vedetta's Conky, never another widget's

---

## 10. Data budget

| Item | Cost |
|---|---|
| Packages (`conky-std` + 3 libraries) | ≈ 1.0 MB download, ≈ 2.7 MB installed, one time |
| Fonts, images, JS, Python dependencies | 0 — DejaVu Sans Mono ships with the distro |
| Runtime network traffic | 0 (no telemetry, no API, no CDN) |
| Disk footprint | ≈ 40 KB config + a few dozen KB of cache |

---

## 11. Fallback

If transparency misbehaves on a given desktop, the escalation ladder is:

1. Toggle `own_window_type` between `normal` and `desktop`, and simplify
   `own_window_hints`.
2. Confirm the compositor is actually running before changing any config.
3. Only then consider a different renderer. The collector is engine-agnostic on
   purpose: it emits plain text, so a GTK or `lemonbar` front end would be a swap,
   not a rewrite.
