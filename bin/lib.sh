#!/usr/bin/env bash
# vedetta :: shared helpers (sourced, never executed directly)
# All formatting is pure-bash: no awk/sed/tr subprocesses in the hot path.

# ---------------------------------------------------------------- canvas
COLS=54                     # hard character budget per line (monospace)

# ---------------------------------------------------------------- palette
C_HEAD='${color #E8924A}'   # amber section titles
C_DIM='${color #6E8898}'    # secondary text / rules
C_TEXT='${color #C8D6E0}'   # body
C_OK='${color #7FCFA8}'     # healthy
C_WARN='${color #E8C34A}'   # elevated
C_CRIT='${color #E86A5E}'   # critical
C_ACC='${color #7EC8E3}'    # accent / numbers
C_RST='${color #C8D6E0}'    # reset
C_TRACK='${color #4A6072}'  # empty part of a bar

# ---------------------------------------------------------------- thresholds
TH_CPU_W=60; TH_CPU_C=85
TH_RAM_W=70; TH_RAM_C=88
TH_TMP_W=70; TH_TMP_C=85
TH_DSK_W=75; TH_DSK_C=90

# ---------------------------------------------------------------- utils
rep() {                     # rep <token> <count>
  local s=$1 n=$2 out= i
  for (( i = 0; i < n; i++ )); do out+=$s; done
  printf '%s' "$out"
}

hcol() {                    # hcol <bytes> -> 15.9G  (0.1 precision, no subprocess)
  local b=${1:-0} i=0 rem=0
  local u=(B K M G T P)
  if [[ ! $b =~ ^[0-9]+$ ]]; then printf '0B'; return; fi
  while (( b >= 1024 && i < 5 )); do
    rem=$(( b % 1024 ))
    b=$(( b / 1024 ))
    i=$(( i + 1 ))
  done
  if (( i == 0 )); then
    printf '%d%s' "$b" "${u[i]}"
  else
    local t=$(( (rem * 10 + 512) / 1024 ))
    if (( t >= 10 )); then b=$(( b + 1 )); t=0; fi
    printf '%d.%d%s' "$b" "$t" "${u[i]}"
  fi
}

bar() {                     # bar <pct> <width> <fillcolor> [trackcolor]
  local pct=${1:-0} w=${2:-10} fill=${3:-$C_OK} track=${4:-$C_TRACK}
  (( pct < 0 )) && pct=0
  (( pct > 100 )) && pct=100
  local f=$(( pct * w / 100 ))
  printf '%s%s%s%s%s' "$fill" "$(rep '▬' "$f")" "$track" "$(rep '▬' $(( w - f )))" "$C_RST"
}

pct_color() {               # pct_color <value> <warn> <crit> -> sets REPLY
  local v=${1:-0}
  if (( v >= $3 )); then REPLY=$C_CRIT
  elif (( v >= $2 )); then REPLY=$C_WARN
  else REPLY=$C_OK; fi
}

hdr() {                     # hdr <TITLE>  ->  " TITLE ──────────"
  local t=" $1 " n
  n=$(( COLS - ${#t} - 1 ))
  (( n < 2 )) && n=2
  printf '%s%s%s%s\n' "$C_HEAD" "$t" "$C_DIM" "$(rep '─' "$n")"
}

trim_mid() {                # trim_mid <string> <max> -> keeps head+tail
  local s=$1 max=$2
  if (( ${#s} <= max )); then printf '%s' "$s"; return; fi
  local keep=$(( max - 1 ))
  printf '%s…' "${s:0:keep}"
}

# keep lines from blowing the canvas
clip() {
  local s=$1
  (( ${#s} > COLS )) && s=${s:0:COLS}
  printf '%s' "$s"
}
