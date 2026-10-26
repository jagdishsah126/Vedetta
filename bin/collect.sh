#!/usr/bin/env bash
# vedetta :: collector
# Emits the entire widget body as Conky markup on stdout.
# Runs standalone for debugging:
#     bash ~/.config/conky/vedetta/bin/collect.sh
#
# Data sources (all unprivileged):
#   /proc/stat, /proc/meminfo, /proc/loadavg, /proc/uptime
#   lsblk, df            -> target-disk partitions, mounted state, space
#   /sys/class/hwmon/*   -> cpu package + cores, fan (resolved by NAME, not index)
#   /sys/class/power_supply/BAT*
#   /sys/class/net/*     -> rx/tx rate from delta cache

BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$BASE/bin/lib.sh"

CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/vedetta"
mkdir -p "$CACHE" 2>/dev/null

san() { printf '%s' "${1//\$/\$\$}"; }   # escape $ for conky's parser

# =====================================================================  system
rootdev=$(findmnt -no SOURCE / 2>/dev/null)
host=$(san "$(cat /etc/hostname 2>/dev/null || echo unknown)")
NAME="" VERSION_ID=""
. /etc/os-release 2>/dev/null
distro="${NAME#Linux } ${VERSION_ID}"

up_s=$(cut -d. -f1 /proc/uptime 2>/dev/null)
up_s=${up_s:-0}
up_d=$(( up_s / 86400 )); up_h=$(( (up_s % 86400) / 3600 )); up_m=$(( (up_s % 3600) / 60 ))
if   (( up_d > 0 )); then uptxt="${up_d}d ${up_h}h"
elif (( up_h > 0 )); then uptxt="${up_h}h ${up_m}m"
else                      uptxt="${up_m}m"; fi

read -r l1 l2 l3 _ < /proc/loadavg
printf -v today '%(%a %d %b %Y)T' -1
printf -v clock '%(%H:%M)T' -1

# =====================================================================  cpu
declare -A P_BUSY P_TOTAL
prevf="$CACHE/cpu.prev"
if [[ -r $prevf ]]; then
  while read -r k b t; do P_BUSY[$k]=$b; P_TOTAL[$k]=$t; done < "$prevf"
fi
: > "$CACHE/cpu.new"

cpu_pct=()
idx=0
while read -r name user nice sys idle iowait irq softirq steal _; do
  [[ $name == cpu[0-9]* ]] || continue
  total=$(( user + nice + sys + idle + iowait + irq + softirq + ${steal:-0} ))
  busy=$(( total - idle - iowait ))
  pb=${P_BUSY[$name]:-0}; pt=${P_TOTAL[$name]:-0}
  dt=$(( total - pt )); db=$(( busy - pb ))
  if (( dt > 0 )); then p=$(( db * 100 / dt )); else p=0; fi
  (( p < 0 )) && p=0; (( p > 100 )) && p=100
  cpu_pct+=("$p")
  echo "$name $busy $total" >> "$CACHE/cpu.new"
  idx=$(( idx + 1 ))
done < /proc/stat
mv -f "$CACHE/cpu.new" "$prevf" 2>/dev/null

cpu_model=$(sed -n 's/^model name[ \t]*: //p' /proc/cpuinfo | head -1 | sed 's/(R)//;s/(TM)//;s/  */ /g')
cpu_model=${cpu_model:-CPU}
gov=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null)

# =====================================================================  memory
mt=0 ma=0 st=0 sf=0
while read -r k v _; do
  case $k in
    MemTotal:)     mt=$(( v * 1024 ));;
    MemAvailable:) ma=$(( v * 1024 ));;
    SwapTotal:)    st=$(( v * 1024 ));;
    SwapFree:)     sf=$(( v * 1024 ));;
  esac
done < /proc/meminfo
mem_used=$(( mt - ma )); (( mem_used < 0 )) && mem_used=0
mem_pct=0; (( mt > 0 )) && mem_pct=$(( mem_used * 100 / mt ))
swap_used=$(( st - sf )); (( swap_used < 0 )) && swap_used=0
swap_pct=0; (( st > 0 )) && swap_pct=$(( swap_used * 100 / st ))

# =====================================================================  health
declare -A HWN
for h in /sys/class/hwmon/hwmon*; do
  n=$(cat "$h/name" 2>/dev/null) || continue
  [[ -n $n ]] && HWN[$n]=$h
done

pkg_t=""; c0_t=""; c1_t=""; fan=""

# CPU package / core temps: prefer the coretemp driver, fall back to any hwmon
if [[ -n ${HWN[coretemp]} ]]; then
  h=${HWN[coretemp]}
  [[ -r $h/temp1_input ]] && pkg_t=$(( $(<"$h/temp1_input") / 1000 ))
  [[ -r $h/temp2_input ]] && c0_t=$(( $(<"$h/temp2_input") / 1000 ))
  [[ -r $h/temp3_input ]] && c1_t=$(( $(<"$h/temp3_input") / 1000 ))
fi
if [[ -z $pkg_t ]]; then
  for h in "${HWN[@]}"; do
    [[ -r $h/temp1_input ]] && { pkg_t=$(( $(<"$h/temp1_input") / 1000 )); break; }
  done
fi

# Fan: whichever hwmon exposes a fan tachometer (driver names vary by vendor)
for h in /sys/class/hwmon/hwmon*; do
  for f in "$h"/fan*_input; do
    if [[ -r $f ]]; then fan=$(<"$f"); break 2; fi
  done
done

bat_pct=""; bat_st=""; bat_v=""
for b in /sys/class/power_supply/BAT*; do
  [[ -d $b ]] || continue
  [[ -r $b/capacity ]] && bat_pct=$(<"$b/capacity")
  [[ -r $b/status ]] && bat_st=$(<"$b/status")
  if [[ -r $b/voltage_now ]]; then
    v=$(( $(<"$b/voltage_now") / 100000 ))
    bat_v="$(( v / 10 )).$(( v % 10 ))V"
  fi
  break
done

# ==============================================================  target disk
# Which disk to report on. Override without editing:
#     VEDETTA_DISK=/dev/nvme0n1 bash bin/collect.sh
DISK=${VEDETTA_DISK:-/dev/sda}
disk_name=${DISK##*/}
declare -A P_SIZE P_FS
parts=()
while IFS= read -r line; do
  [[ $line =~ NAME=\"([^\"]+)\"\ SIZE=\"([0-9]+)\"\ TYPE=\"([^\"]+)\"\ FSTYPE=\"([^\"]*)\" ]] || continue
  [[ ${BASH_REMATCH[3]} == part ]] || continue
  nm=${BASH_REMATCH[1]}
  parts+=("$nm")
  P_SIZE[$nm]=${BASH_REMATCH[2]}
  P_FS[$nm]=${BASH_REMATCH[4]}
done < <(lsblk -b -P -o NAME,SIZE,TYPE,FSTYPE "$DISK" 2>/dev/null)

declare -A M_TGT M_USED M_AVAIL M_SIZE
while read -r src fstype size used avail target; do
  [[ $src == "/dev/$disk_name"* ]] || continue
  k=${src#/dev/}
  [[ -n ${M_TGT[$k]} ]] && continue
  M_TGT[$k]=$target; M_SIZE[$k]=$size; M_USED[$k]=$used; M_AVAIL[$k]=$avail
done < <(df -B1 --output=source,fstype,size,used,avail,target 2>/dev/null | tail -n +2)

# testing hook (no root needed): VEDETTA_FAKE_UNMOUNT=sda3,sda5
if [[ -n ${VEDETTA_FAKE_UNMOUNT:-} ]]; then
  for _f in ${VEDETTA_FAKE_UNMOUNT//,/ }; do
    unset 'M_TGT[$_f]' 'M_SIZE[$_f]' 'M_USED[$_f]' 'M_AVAIL[$_f]'
  done
  unset _f
fi

disk_size=$(lsblk -bno SIZE "$DISK" 2>/dev/null | head -1)
disk_size=${disk_size:-0}
sum_part=0; sum_used=0; sum_avail=0
for p in "${parts[@]}"; do
  sum_part=$(( sum_part + ${P_SIZE[$p]:-0} ))
  if [[ -n ${M_TGT[$p]} ]]; then
    sum_used=$(( sum_used + ${M_USED[$p]:-0} ))
    sum_avail=$(( sum_avail + ${M_AVAIL[$p]:-0} ))
  fi
done
unalloc=$(( disk_size - sum_part )); (( unalloc < 0 )) && unalloc=0

# =====================================================================  net
declare -A N_RX N_TX N_IF
now=$(date +%s%N)
prevf="$CACHE/net.prev"
if [[ -r $prevf ]]; then
  while read -r ifc ts rx tx; do
    N_IF[$ifc]=$ts; N_RX[$ifc]=$rx; N_TX[$ifc]=$tx
  done < "$prevf"
fi
out_net=()
for d in /sys/class/net/*; do
  ifc=${d##*/}
  [[ $ifc == lo ]] && continue
  [[ -r $d/operstate ]] || continue
  [[ $(<"$d/operstate") == up ]] || continue
  rx=$(<"$d/statistics/rx_bytes"); tx=$(<"$d/statistics/tx_bytes")
  prx=${N_RX[$ifc]:-0}; ptx=${N_TX[$ifc]:-0}; pts=${N_IF[$ifc]:-0}
  dt=$(( now - pts ))
  if (( pts > 0 && dt > 0 )); then
    drx=$(( (rx - prx) * 1000000000 / dt ))
    dtx=$(( (tx - ptx) * 1000000000 / dt ))
  else
    drx=0; dtx=0
  fi
  (( drx < 0 )) && drx=0; (( dtx < 0 )) && dtx=0
  out_net+=("$ifc $drx $dtx")
done
: > "$CACHE/net.prev.new"
for d in /sys/class/net/*; do
  ifc=${d##*/}
  [[ $ifc == lo ]] && continue
  echo "$ifc $now $(<"$d/statistics/rx_bytes") $(<"$d/statistics/tx_bytes")" >> "$CACHE/net.prev.new"
done
mv -f "$CACHE/net.prev.new" "$CACHE/net.prev" 2>/dev/null

# =====================================================================  render
emit() { printf '%s\n' "$1"; }

emit "${C_HEAD} ● VEDETTA ${C_DIM}$(rep '─' $(( COLS - 13 )))"
emit "${C_TEXT} $(san "$host")  ${C_DIM}·${C_TEXT}  $distro  ${C_DIM}·${C_TEXT}  up $uptxt"
emit "${C_DIM} $(san "$today")   ${C_ACC}$clock${C_RST}"
echo

emit "$(hdr CPU)"
emit "${C_DIM} $(san "$cpu_model")  ${C_DIM}·${C_TEXT} $gov"
fsum=0; fcnt=0
for cf in /sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq; do
  [[ -r $cf ]] && { fsum=$(( fsum + $(<"$cf") )); fcnt=$(( fcnt + 1 )); }
done
freqavg=0; (( fcnt > 0 )) && freqavg=$(( fsum / fcnt / 1000 ))
emit "${C_DIM} load ${C_TEXT}$l1 ${C_DIM}$l2 $l3  ${C_DIM}· ${C_ACC}${freqavg}MHz"

# 24-sample CPU history sparkline  (concept: cpugraph in kambei/conky-orange,
#                                  graded scale idea: philer/polycore, MIT)
SPARK=(▁ ▂ ▃ ▄ ▅ ▆ ▇ █)
histf="$CACHE/cpu.hist"
declare -a hist=()
[[ -r $histf ]] && read -r -a hist < "$histf"
avg=0
if (( ${#cpu_pct[@]} > 0 )); then
  s=0; for p in "${cpu_pct[@]}"; do s=$(( s + p )); done
  avg=$(( s / ${#cpu_pct[@]} ))
fi
hist+=("$avg")
(( ${#hist[@]} > 24 )) && hist=("${hist[@]: -24}")
printf '%s\n' "${hist[*]}" > "$histf"
spark=""
for v in "${hist[@]}"; do
  i=$(( v * 7 / 100 )); (( i > 7 )) && i=7; (( i < 0 )) && i=0
  spark+="${SPARK[$i]}"
done
pct_color "$avg" $TH_CPU_W $TH_CPU_C
printf -v p3 '%3s' "$avg"
emit "${C_DIM}   ${REPLY}${spark}${C_RST} ${C_DIM}${p3}%${C_RST}"
tline="${C_DIM}   "
t=1
for p in "${cpu_pct[@]}"; do
  pct_color "$p" $TH_CPU_W $TH_CPU_C
  printf -v p3 '%3s' "$p"
  tline+="T${t} ${REPLY}${p3}%${C_RST}   "
  t=$(( t + 1 ))
done
emit "${tline%   }"
echo

emit "$(hdr MEMORY)"
mem_bar_pc=$mem_pct
pct_color "$mem_pct" $TH_RAM_W $TH_RAM_C
printf -v p3 '%3s' "$mem_pct"
line="${C_DIM}   RAM  ${C_ACC}$(hcol "$mem_used")${C_DIM} / $(hcol "$mt")   "
line+="$(bar "$mem_pct" 12 "$REPLY") ${REPLY}${p3}%${C_RST}"
emit "$line"
pct_color "$swap_pct" $TH_RAM_W $TH_RAM_C
printf -v p3 '%3s' "$swap_pct"
line="${C_DIM}   SWAP ${C_ACC}$(hcol "$swap_used")${C_DIM} / $(hcol "$st")   "
line+="$(bar "$swap_pct" 12 "$REPLY") ${REPLY}${p3}%${C_RST}"
emit "$line"
echo

emit "$(hdr 'PC HEALTH')"
if [[ -n $pkg_t ]]; then
  pct_color "$pkg_t" $TH_TMP_W $TH_TMP_C; tc=$REPLY
else tc=$C_DIM; fi
line="   cpu "
if [[ -n $pkg_t ]]; then line+="${tc}${pkg_t}°C "; else line+="${C_DIM}n/a "; fi
if [[ -n $c0_t && -n $c1_t ]]; then line+="${C_DIM}cores ${C_TEXT}${c0_t}/${c1_t}°C "; fi
if [[ -n $fan && $fan -gt 0 ]]; then line+="${C_DIM}fan ${C_TEXT}${fan}rpm"; else line+="${C_DIM}fan —"; fi
emit "$line"
line="   bat "
if [[ -n $bat_pct ]]; then
  pct_color $(( 100 - bat_pct )) 40 25
  line+="${C_TEXT}${bat_pct}% ${C_DIM}${bat_st} ${C_DIM}${bat_v}"
else
  line+="${C_DIM}not present"
fi
emit "$line"
echo

emit "$(hdr "$(printf '%s' "$disk_name" | tr '[:lower:]' '[:upper:]') — DISKS")"
i_part=0
for p in "${parts[@]}"; do
  size=${P_SIZE[$p]:-0}; fs=${P_FS[$p]:-?}
  mp=${M_TGT[$p]:-}
  if [[ -n $mp ]]; then
    printf '%s %-5s %s%-18s %s%-4s %s● mounted\n' \
      "$C_TEXT" "$p" "$C_ACC" "$(san "$(trim_mid "$mp" 18)")" "$C_DIM" "$fs" "$C_OK"
    used=${M_USED[$p]:-0}; avail=${M_AVAIL[$p]:-0}
    fssize=${M_SIZE[$p]:-$size}
    rsv=$(( fssize - used - avail )); (( rsv < 0 )) && rsv=0
    denom=$(( used + avail ))
    pc=0; (( denom > 0 )) && pc=$(( used * 100 / denom ))
    pct_color "$pc" $TH_DSK_W $TH_DSK_C
    printf -v p3 '%3s' "$pc"
    line="${C_DIM}   ${C_ACC}$(hcol "$used")${C_DIM} used "
    line+="${C_ACC}$(hcol "$avail")${C_DIM} free "
    line+="${C_ACC}$(hcol "$rsv")${C_DIM} rsv  "
    line+="$(bar "$pc" 10 "$REPLY") ${REPLY}${p3}%${C_RST}"
    emit "$line"
  else
    printf '%s %-5s %s%-18s %s%-4s %s○ unmounted\n' \
      "$C_DIM" "$p" "$C_DIM" "$(san "$(trim_mid "$mp" 18)")" "$C_DIM" "$fs" "$C_WARN"
    printf '%s   %s%s size  %s— used  %s— free  %s— rsv\n' \
      "$C_DIM" "$C_DIM" "$(hcol "$size")" "$C_DIM" "$C_DIM" "$C_DIM"
  fi
  (( i_part++ < ${#parts[@]} - 1 )) && emit ""
done
printf '%s   %s%s total  %s%s used  %s%s free%s\n' \
  "$C_DIM" "$C_TEXT" "$(hcol "$disk_size")" "$C_TEXT" "$(hcol "$sum_used")" \
  "$C_TEXT" "$(hcol "$sum_avail")" "$C_DIM"
if (( unalloc > 1048576 )); then
  printf '%s   %s%s unallocated%s\n' "$C_DIM" "$C_DIM" "$(hcol "$unalloc")" "$C_DIM"
fi
echo

if (( ${#out_net[@]} > 0 )); then
  emit "$(hdr NETWORK)"
  for e in "${out_net[@]}"; do
    read -r ifc drx dtx <<< "$e"
    printf '%s   %-12s %s↓ %s/s  %s↑ %s/s%s\n' \
      "$C_DIM" "$(san "$ifc")" "$C_OK" "$(hcol "$drx")" "$C_WARN" "$(hcol "$dtx")" "$C_RST"
  done
else
  emit "$(hdr NETWORK)"
  emit "${C_DIM}   no active interface"
fi
