# Credits & upstream sources

Vedetta is **configuration plus a Bash collector**, not a fork of anything. This file
records exactly what came from where, so the debt stays traceable.

---

## 1. Engine (used, not modified)

| Project | Licence | How it is used |
|---|---|---|
| **[brndnmtthws/conky](https://github.com/brndnmtthws/conky)** ★8.5k | GPL-3.0 | The renderer. Installed from the distribution as `conky-std 1.19.x`. No source changes — only `conky.conf` is authored. |

That is the "engine already exists" argument in practice: drawing, the X11 window,
transparency and the update loop are all Conky's. None of it is reimplemented here.

---

## 2. Patterns adopted from public configs

These are **functional settings and layout ideas**, re-expressed in this project's own
files. No source code was copy-pasted.

### [kambei/conky-orange](https://github.com/kambei/conky-orange) ★0 · GPL-3.0

The closest conceptual match found (orange accents, CPU/RAM/DISK/NETWORK sections).
Adopted from its `conky.conf`:

| Setting | Why |
|---|---|
| `double_buffer = true` | flicker-free repaint on a translucent window |
| `cpu_avg_samples = 2` | smooths CPU% so a 2 s refresh doesn't jump |
| `net_avg_samples = 2` | same for network rates |
| `no_buffers = true` | RAM figure without cache, matching `free -h` expectations |
| `xinerama_head = 0` | explicit monitor target |
| `alignment = 'top_right'`, `gap_x ≈ 35` | the right-side placement convention |

Its `${cpugraph}` idea became this project's **24-sample CPU sparkline**, implemented in
Bash (no Conky graph widget), so it still works outside Conky.

### [philer/polycore](https://github.com/philer/polycore) ★89 · **MIT**

A Lua widget library. Not vendored — it would have required a Cairo/Lua renderer, which
was explicitly out of scope. Two ideas were taken:

- **Graded threshold → colour mapping** (`temperature_colors` table) → became the
  `TH_*_W` / `TH_*_C` warn/critical pairs in `bin/lib.sh`.
- Its separation of **data / rendering / layout** informed this project's split between
  `collect.sh` (data + text) and `conky.conf` (window + geometry).

If you ever want cairo-drawn rings/gauges, polycore is the library to reach for, and its
MIT licence allows direct reuse.

### [zagortenay333/conky_themes](https://github.com/zagortenay333/conky_themes) ★638

Reviewed (*harmattan*, *jelly*, *vision*). **Nothing adopted**: those themes are
Lua/Cairo compositions that ship their own SVG asset sets and renderer; there is no
transferable config fragment for a text-mode widget. Worth reading for layout ideas only.

### Others reviewed, nothing adopted

| Repo | Reason |
|---|---|
| [mrmierzejewski/conkyrc](https://github.com/mrmierzejewski/conkyrc) | different shape (weather/clock heavy) |
| [gvoze32/Mainte](https://github.com/gvoze32/Mainte) | theme bundle, no disk-status logic |
| [AguilarLagunasArturo/conky-themes](https://github.com/AguilarLagunasArturo/conky-themes) | collection, nothing closer than conky-orange |
| [maxiwell/conky-seamod](https://github.com/maxiwell/conky-seamod) | Lua 1.10-era config, incompatible assumptions |
| [mik30s/Cysboard](https://github.com/mik30s/Cysboard) ★160 | dead since 2017; C++ engine + HTML themes, no reuse possible |

---

## 3. What is original here

Everything not listed above:

- The **partition-centric model** — joining `lsblk` with `df` so unmounted partitions
  still appear with size and an explicit `○ unmounted` state. None of the reviewed
  configs do this; they all rely on `$fs_*`, which only sees mounted paths.
- The **reserved-space column** (`fs_size − used − available`), computed without root.
- The **54-column monospace canvas** and two-colour `▬` gauges with a recessed track.
- The **controller** (`vedetta start|stop|size|tint|save-pos|watch`), the position
  watcher, autostart wiring, and the `VEDETTA_FAKE_UNMOUNT` test hook.
- The **sparkline** and **bar** implementations in pure Bash (no subprocesses in the
  hot path).

---

## 4. Licence position

- This project's own files are **MIT** — see [LICENSE](LICENSE).
- Conky itself is **GPL-3.0**. Configuring it does not make this project a derivative
  work, but redistributing Conky binaries would.
- `kambei/conky-orange` is **GPL-3.0**. Only non-copyrightable configuration values
  were adopted, not code — no GPL obligation is inherited. If you ever copy actual
  lines from it, that changes: the file would need to carry GPL-3.0.
- `philer/polycore` is **MIT** — safe to vendor with attribution if you extend this.
