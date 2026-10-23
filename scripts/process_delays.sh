#!/usr/bin/env bash
# process_delays.sh - Delay Calculation & Processing module.
# Usage: scripts/process_delays.sh [timetable.csv] [live_updates.csv] [output.csv]
# Defaults: data/timetable.csv  data/live_updates.csv  data/processed_delays.csv
# Env:      CONFIG=path/to/thresholds.conf  (default config/thresholds.conf)
# Exit:     0 = ran (rejected rows are only counted), 1 = bad usage/config/file, 2 = bad header
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG="${CONFIG:-$ROOT/config/thresholds.conf}"
TIMETABLE="${1:-$ROOT/data/timetable.csv}"
LIVE="${2:-$ROOT/data/live_updates.csv}"
OUT="${3:-$ROOT/data/processed_delays.csv}"

TT_HEADER="service_date,trip_id,route_id,stop_id,stop_sequence,scheduled_arrival_utc"
LIVE_HEADER="service_date,trip_id,vehicle_id,stop_id,stop_sequence,actual_arrival_utc,confidence"

die() { echo "ERROR: $*" >&2; exit "${2:-1}"; }

[[ -r "$CONFIG"    ]] || die "config not readable: $CONFIG"
[[ -r "$TIMETABLE" ]] || die "timetable not readable: $TIMETABLE"
[[ -r "$LIVE"      ]] || die "live updates not readable: $LIVE"

# Read thresholds (ignores comments, spaces, quotes, CRLF).
get_conf() { grep -E "^[[:space:]]*$1=" "$CONFIG" | tail -n1 | cut -d= -f2- | tr -d ' \t\r"'"'"; }
ON_TIME_MAX_MIN="$(get_conf ON_TIME_MAX_MIN || true)"
MAJOR_DELAY_MIN="$(get_conf MAJOR_DELAY_MIN || true)"
num_re='^[0-9]+(\.[0-9]+)?$'
[[ "$ON_TIME_MAX_MIN" =~ $num_re ]] || die "ON_TIME_MAX_MIN missing or not a non-negative number in $CONFIG"
[[ "$MAJOR_DELAY_MIN" =~ $num_re ]] || die "MAJOR_DELAY_MIN missing or not a non-negative number in $CONFIG"
awk -v a="$ON_TIME_MAX_MIN" -v b="$MAJOR_DELAY_MIN" 'BEGIN{exit !(a+0 < b+0)}' \
  || die "ON_TIME_MAX_MIN ($ON_TIME_MAX_MIN) must be less than MAJOR_DELAY_MIN ($MAJOR_DELAY_MIN)"

# Header checks (exact column names and order are part of the agreed schema).
[[ "$(head -n1 "$TIMETABLE" | tr -d '\r')" == "$TT_HEADER"   ]] || die "timetable header must be: $TT_HEADER" 2
[[ "$(head -n1 "$LIVE"      | tr -d '\r')" == "$LIVE_HEADER" ]] || die "live updates header must be: $LIVE_HEADER" 2

mkdir -p "$(dirname "$OUT")"
TMP="$(mktemp "${OUT}.XXXXXX")"
trap 'rm -f "$TMP"' EXIT

awk -v on_sec="$(awk -v a="$ON_TIME_MAX_MIN" 'BEGIN{printf "%d", a*60}')" \
    -v maj_sec="$(awk -v b="$MAJOR_DELAY_MIN" 'BEGIN{printf "%d", b*60}')" '
# ISO-8601 UTC "YYYY-MM-DDTHH:MM:SSZ" -> epoch seconds, or -1 if invalid.
# Pure awk arithmetic (works in mawk and gawk). Both inputs are UTC, so midnight
# crossings need no special handling: subtracting epochs is always correct.
function to_epoch(ts,   y,m,d,H,M,S,era,yoe,doy,doe) {
  if (ts !~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z$/) return -1
  y=substr(ts,1,4)+0; m=substr(ts,6,2)+0; d=substr(ts,9,2)+0
  H=substr(ts,12,2)+0; M=substr(ts,15,2)+0; S=substr(ts,18,2)+0
  if (m<1 || m>12 || d<1 || d>31 || H>23 || M>59 || S>59) return -1
  if (m<=2) y--
  era=int(y/400); yoe=y-era*400
  doy=int((153*(m+(m>2?-3:9))+2)/5)+d-1
  doe=yoe*365+int(yoe/4)-int(yoe/100)+doy
  return (era*146097+doe-719468)*86400 + H*3600 + M*60 + S
}
BEGIN { FS="," }
{ sub(/\r$/, "") }

# ---- File 1: timetable -------------------------------------------------
FILENAME == ARGV[1] {
  if (FNR == 1) next
  tt_read++
  if (NF != 6 || $1=="" || $2=="" || $3=="" || $4=="" || $5=="" || $6=="" || $5 !~ /^[0-9]+$/) { tt_rej++; next }
  e = to_epoch($6)
  if (e < 0) { tt_rej++; next }
  k = $1 "|" $2 "|" ($5+0)
  if (k in sched) { tt_dup++; next }
  tt_valid++
  sched[k] = e; sched_ts[k] = $6; route[k] = $3; stopid[k] = $4
  next
}

# ---- File 2: live updates ----------------------------------------------
{
  if (FNR == 1) next
  live_read++
  if (NF != 7)                                  { r_fields++; next }
  if ($1=="" || $2=="" || $3=="" || $4=="" || $5=="" || $6=="" || $7=="") { r_empty++; next }
  if ($7 != "high" && $7 != "medium")           { r_conf++;   next }
  if ($5 !~ /^[0-9]+$/)                         { r_seq++;    next }
  e = to_epoch($6)
  if (e < 0)                                    { r_ts++;     next }
  k = $1 "|" $2 "|" ($5+0)
  if (!(k in sched))                            { r_nomatch++; next }
  if ($4 != stopid[k])                          { r_stop++;   next }
  rank = ($7 == "high") ? 2 : 1
  if (k in best) {
    live_dup++                                  # duplicate key: higher confidence wins;
    if (rank < best_rank[k]) next               # on a tie the later row in the file wins
  } else { n++; order[n] = k }
  best_rank[k] = rank; best[k] = 1
  veh[k] = $3; act_ts[k] = $6; act[k] = e; conf[k] = $7
}

END {
  print "service_date,trip_id,route_id,vehicle_id,stop_id,stop_sequence,scheduled_arrival_utc,actual_arrival_utc,delay_min,status,confidence"
  for (i = 1; i <= n; i++) {
    k = order[i]; split(k, p, "|")
    d = act[k] - sched[k]
    status = (d <= on_sec) ? "ON_TIME" : ((d >= maj_sec) ? "MAJOR_DELAY" : "DELAYED")
    printf "%s,%s,%s,%s,%s,%s,%s,%s,%.2f,%s,%s\n", p[1], p[2], route[k], veh[k], stopid[k], p[3], sched_ts[k], act_ts[k], d/60, status, conf[k]
  }
  for (k in sched) if (!(k in best)) no_live++
  s = "/dev/stderr"
  print "timetable_rows_read="               tt_read+0   > s
  print "timetable_rows_valid="              tt_valid+0  > s
  print "timetable_rows_rejected="           tt_rej+0    > s
  print "timetable_duplicates_ignored="      tt_dup+0    > s
  print "live_rows_read="                    live_read+0 > s
  print "live_rows_matched="                 n+0         > s
  print "live_duplicates_superseded="        live_dup+0  > s
  print "live_rejected_bad_field_count="     r_fields+0  > s
  print "live_rejected_empty_field="         r_empty+0   > s
  print "live_rejected_bad_confidence="      r_conf+0    > s
  print "live_rejected_bad_stop_sequence="   r_seq+0     > s
  print "live_rejected_bad_timestamp="       r_ts+0      > s
  print "live_rejected_no_timetable_match="  r_nomatch+0 > s
  print "live_rejected_stop_id_mismatch="    r_stop+0    > s
  print "timetable_rows_without_live="       no_live+0   > s
  print "output_rows_written="               n+0         > s
}' "$TIMETABLE" "$LIVE" > "$TMP"

mv "$TMP" "$OUT"
trap - EXIT
