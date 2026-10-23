#!/usr/bin/env bash
# Runs process_delays.sh against hand-written fixtures and fails on any difference.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SCRIPT="$ROOT/scripts/process_delays.sh"
FX="$HERE/fixtures"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }

# 1. Main fixture: output file and summary counts
"$SCRIPT" "$FX/timetable.csv" "$FX/live_updates.csv" "$TMP/out.csv" 2> "$TMP/summary.txt"
diff -u "$FX/expected_output.csv" "$TMP/out.csv"      && ok "output matches expected"  || bad "output differs"
diff -u "$FX/expected_summary.txt" "$TMP/summary.txt" && ok "summary matches expected" || bad "summary differs"

# 2. Custom thresholds change classification (3/6 instead of 5/15)
printf 'ON_TIME_MAX_MIN=3\nMAJOR_DELAY_MIN=6\n' > "$TMP/t.conf"
CONFIG="$TMP/t.conf" "$SCRIPT" "$FX/timetable.csv" "$FX/live_updates.csv" "$TMP/out2.csv" 2>/dev/null
grep -q ',6.00,MAJOR_DELAY,' "$TMP/out2.csv" && grep -q ',5.00,DELAYED,' "$TMP/out2.csv" \
  && ok "custom thresholds respected" || bad "custom thresholds ignored"

# 3. Bad config: thresholds in wrong order -> exit 1
printf 'ON_TIME_MAX_MIN=10\nMAJOR_DELAY_MIN=5\n' > "$TMP/bad.conf"
CONFIG="$TMP/bad.conf" "$SCRIPT" "$FX/timetable.csv" "$FX/live_updates.csv" "$TMP/o3.csv" 2>/dev/null
[[ $? -eq 1 ]] && ok "bad config rejected (exit 1)" || bad "bad config not rejected"

# 4. Non-numeric threshold -> exit 1
printf 'ON_TIME_MAX_MIN=abc\nMAJOR_DELAY_MIN=15\n' > "$TMP/bad2.conf"
CONFIG="$TMP/bad2.conf" "$SCRIPT" "$FX/timetable.csv" "$FX/live_updates.csv" "$TMP/o4.csv" 2>/dev/null
[[ $? -eq 1 ]] && ok "non-numeric threshold rejected" || bad "non-numeric threshold accepted"

# 5. Missing input file -> exit 1, no output file left behind
"$SCRIPT" "$TMP/nope.csv" "$FX/live_updates.csv" "$TMP/o5.csv" 2>/dev/null
[[ $? -eq 1 && ! -e "$TMP/o5.csv" ]] && ok "missing file -> exit 1, no output" || bad "missing file handling"

# 6. Wrong header -> exit 2
printf 'a,b,c\n1,2,3\n' > "$TMP/wronghdr.csv"
"$SCRIPT" "$TMP/wronghdr.csv" "$FX/live_updates.csv" "$TMP/o6.csv" 2>/dev/null
[[ $? -eq 2 ]] && ok "wrong header -> exit 2" || bad "wrong header not caught"

# 7. Header-only live file -> header-only output, exit 0
head -n1 "$FX/live_updates.csv" > "$TMP/emptylive.csv"
"$SCRIPT" "$FX/timetable.csv" "$TMP/emptylive.csv" "$TMP/o7.csv" 2>/dev/null
[[ $? -eq 0 && $(wc -l < "$TMP/o7.csv") -eq 1 ]] && ok "empty live file -> header only" || bad "empty live file handling"

# 8. CRLF line endings are tolerated
sed 's/$/\r/' "$FX/timetable.csv" > "$TMP/tt_crlf.csv"; sed 's/$/\r/' "$FX/live_updates.csv" > "$TMP/lv_crlf.csv"
"$SCRIPT" "$TMP/tt_crlf.csv" "$TMP/lv_crlf.csv" "$TMP/o8.csv" 2>/dev/null
diff -q "$FX/expected_output.csv" "$TMP/o8.csv" >/dev/null && ok "CRLF input handled" || bad "CRLF input mishandled"

echo; echo "$pass passed, $fail failed"; [[ $fail -eq 0 ]]
