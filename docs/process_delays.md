## Delay Calculation & Processing (`scripts/process_delays.sh`)

Matches scheduled arrivals to live arrivals, computes delay in minutes, classifies each record, and writes `data/processed_delays.csv` for the reporting and alert modules. Bash + awk only.

### Run

```bash
scripts/process_delays.sh                       # uses data/timetable.csv, data/live_updates.csv -> data/processed_delays.csv
scripts/process_delays.sh TT.csv LIVE.csv OUT.csv   # explicit paths
CONFIG=/path/thresholds.conf scripts/process_delays.sh
tests/run_tests.sh                              # test suite (hand-written fixtures)
```

Exit codes: `0` ran (bad rows are counted, not fatal), `1` missing file / invalid config, `2` wrong header.
A count summary (rows read, matched, rejected per reason) is printed to **stderr**. It is not a log file.

### Input schema (agreed with ingestion module)

`data/timetable.csv` (header required, exact order):
`service_date,trip_id,route_id,stop_id,stop_sequence,scheduled_arrival_utc`

`data/live_updates.csv` (header required, exact order):
`service_date,trip_id,vehicle_id,stop_id,stop_sequence,actual_arrival_utc,confidence`

- Comma-delimited, UTF-8, no quoted fields or embedded commas. LF or CRLF accepted.
- All IDs are **strings** (e.g. `vehicle_id` `0968` keeps its leading zero).
- `confidence` must be `high` or `medium`. Rows without an actual time must not be in the live file.

### Timestamp rules

- Format: `YYYY-MM-DDTHH:MM:SSZ`, **UTC**, whole seconds. Nothing else is accepted (no `25:10:00`, no AM/PM, no time-only values).
- `service_date` is the **local** service day, not the UTC date. It is used for matching only, never derived from a timestamp. (E.g. `2026-04-17` with a scheduled time of `2026-04-18T00:40:00Z` is correct.)
- Delay is `actual_epoch - scheduled_epoch`. Because both are full UTC timestamps, arrivals crossing midnight need no special handling (`23:58Z` scheduled, `00:04Z` next day actual = +6.00 min).
- Early arrivals produce a **negative** `delay_min` and are classified ON_TIME.
- Precision is whole seconds. If the source has sub-second times, ingestion truncates them, so a delay of 300.5 s becomes 300 s.

### Matching

Join key: `service_date + trip_id + stop_sequence`. `stop_id` is then cross-checked, and a mismatch is rejected.
Duplicate live rows for one key: higher confidence wins (`high` > `medium`); on a tie, the later row in the file wins.
Duplicate timetable keys: first row wins.

### Thresholds (`config/thresholds.conf`)

| Setting | Default | Meaning |
|---|---|---|
| `ON_TIME_MAX_MIN` | 5 | `delay_min <= 5` is ON_TIME (inclusive, includes early) |
| `MAJOR_DELAY_MIN` | 15 | `delay_min >= 15` is MAJOR_DELAY (inclusive) |

Anything in between is DELAYED. Boundaries are compared in whole seconds, so exactly 5.00 is ON_TIME and exactly 15.00 is MAJOR_DELAY. `ON_TIME_MAX_MIN` must be less than `MAJOR_DELAY_MIN`; invalid config stops the run (exit 1).

### Output schema: `data/processed_delays.csv`

`service_date,trip_id,route_id,vehicle_id,stop_id,stop_sequence,scheduled_arrival_utc,actual_arrival_utc,delay_min,status,confidence`

`delay_min` has 2 decimals (negative = early). `status` is `ON_TIME`, `DELAYED` or `MAJOR_DELAY`. Rows follow live-file order. The file is replaced atomically, so a failed run never leaves a partial output.
**The reporting and alert modules must agree to this column list before it changes.**

### Rejected rows (counted in the stderr summary)

Wrong field count, empty field, bad confidence, non-numeric `stop_sequence`, malformed timestamp, no timetable match, `stop_id` mismatch. Timetable rows with no live update are counted as `timetable_rows_without_live` and are **not** errors (no data yet, or low-confidence upstream).

### Tests

`tests/run_tests.sh` runs 9 checks: a fixture covering on-time, early, both boundaries, major delay, midnight crossing, duplicates, and each malformed-data case (compared to hand-written expected output and counts), plus custom thresholds, bad config, missing file, wrong header, empty live file and CRLF input.

### Known limitations

No quoted-CSV support. Dates are not checked per month (e.g. `2026-02-31` passes). Verified on mawk 1.3.4. The awk code is plain POSIX, but gawk was not tested.
