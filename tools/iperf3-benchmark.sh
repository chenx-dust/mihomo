#!/usr/bin/env bash

set -u

SCRIPT_NAME="$(basename "$0")"
PORT=5201
DURATION=5
PARALLEL_CSV="1,2,4,8,16"
UDP_RATES_CSV="300M,1G,3G,10G"
IPERF_ARGS=(-4)
MIHOMO_PID=""
CONTROLLER_URL="http://127.0.0.1:9090"
TMP_DIR=""
FAILURES=0
GC_FAILURES=0
RESULTS=()
BEST_BPS=0
BEST_LABEL=""
UDP_LOSS_ALERT=""

usage() {
  cat <<EOF
Usage: $SCRIPT_NAME <server-ip> [options]

Run a high-load IPv4 LAN benchmark against an iperf3 server.
Each test also reports the mihomo process' peak resident memory (RSS).
CPU usage is averaged over each test; 100% represents one fully used core.
After each test, the script calls PUT <controller>/debug/gc.

Options:
  -p, --port PORT          iperf3 server port (default: 5201)
  -t, --time SECONDS       duration of each test (default: 5)
  -P, --parallel LIST      TCP parallel streams, comma-separated (default: 1,2,4,8,16)
      --udp-rates LIST     UDP target rates, comma-separated (default: 1G,2G,5G,10G)
      --mihomo-pid PID      mihomo process to monitor (auto-detected if unique)
      --controller URL      mihomo external controller (default: http://127.0.0.1:9090)
  -4                       force IPv4 (default)
  -h, --help               show this help

The remote server must be started separately, for example:
  iperf3 -s -p 5201
EOF
}

die() {
  echo "Error: $*" >&2
  exit 2
}

is_positive_integer() { [[ "$1" =~ ^[1-9][0-9]*$ ]]; }
is_rate() { [[ "$1" =~ ^[1-9][0-9]*(K|M|G|T)$ ]]; }

validate_csv() {
  local value="$1" kind="$2" item
  IFS=',' read -r -a items <<< "$value"
  ((${#items[@]} > 0)) || return 1
  for item in "${items[@]}"; do
    if [[ "$kind" == parallel ]]; then
      is_positive_integer "$item" || return 1
    else
      is_rate "$item" || return 1
    fi
  done
}

while (($#)); do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    -4) IPERF_ARGS=(-4); shift ;;
    -p|--port)
      (($# >= 2)) || die "missing value for $1"
      PORT="$2"; shift 2 ;;
    -t|--time)
      (($# >= 2)) || die "missing value for $1"
      DURATION="$2"; shift 2 ;;
    -P|--parallel)
      (($# >= 2)) || die "missing value for $1"
      PARALLEL_CSV="$2"; shift 2 ;;
    --udp-rates)
      (($# >= 2)) || die "missing value for $1"
      UDP_RATES_CSV="$2"; shift 2 ;;
    --mihomo-pid)
      (($# >= 2)) || die "missing value for $1"
      is_positive_integer "$2" || die "mihomo-pid must be a positive integer"
      MIHOMO_PID="$2"; shift 2 ;;
    --controller)
      (($# >= 2)) || die "missing value for $1"
      [[ -n "$2" ]] || die "controller URL must not be empty"
      CONTROLLER_URL="${2%/}"; shift 2 ;;
    --) shift; break ;;
    -*) die "unknown option: $1" ;;
    *)
      [[ -z "${SERVER:-}" ]] || die "only one server address may be supplied"
      SERVER="$1"; shift ;;
  esac
done

[[ -n "${SERVER:-}" ]] || { usage >&2; exit 2; }
is_positive_integer "$PORT" || die "port must be a positive integer"
((PORT <= 65535)) || die "port must be between 1 and 65535"
is_positive_integer "$DURATION" || die "time must be a positive integer"
validate_csv "$PARALLEL_CSV" parallel || die "parallel must be comma-separated positive integers"
validate_csv "$UDP_RATES_CSV" rate || die "udp-rates must contain values such as 1G,500M"

if [[ -z "$MIHOMO_PID" ]] && command -v pgrep >/dev/null 2>&1; then
  mapfile -t mihomo_pids < <(pgrep -x mihomo 2>/dev/null || true)
  if ((${#mihomo_pids[@]} == 1)); then
    MIHOMO_PID="${mihomo_pids[0]}"
  elif ((${#mihomo_pids[@]} > 1)); then
    echo "Warning: multiple mihomo processes found; use --mihomo-pid PID to select one. Memory will be N/A." >&2
  fi
fi
if [[ -n "$MIHOMO_PID" ]] && ! kill -0 "$MIHOMO_PID" 2>/dev/null; then
  die "mihomo process $MIHOMO_PID was not found"
fi
if [[ -z "$MIHOMO_PID" ]]; then
  echo "Warning: mihomo process not found; memory statistics will be N/A. Use --mihomo-pid PID if needed." >&2
fi

command -v iperf3 >/dev/null 2>&1 || die "iperf3 was not found in PATH"
command -v curl >/dev/null 2>&1 || die "curl was not found in PATH"
if command -v python3 >/dev/null 2>&1; then
  PARSER="python3"
elif command -v jq >/dev/null 2>&1; then
  PARSER="jq"
else
  die "either jq or python3 is required to parse iperf3 JSON output"
fi

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/iperf3-benchmark.XXXXXX")" || die "cannot create temporary directory"
cleanup() { [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]] && rm -rf "$TMP_DIR"; }
trap cleanup EXIT INT TERM

format_number() {
  awk -v n="$1" 'BEGIN { if (n >= 1000000000) printf "%.2f Gbps", n/1000000000; else if (n >= 1000000) printf "%.2f Mbps", n/1000000; else printf "%.0f bps", n }'
}

format_decimal() {
  awk -v n="${1:-0}" 'BEGIN { if (n == "" || n == "null") n=0; printf "%.2f", n }'
}

format_memory() {
  awk -v kb="${1-}" 'BEGIN {
    if (kb == "" || kb !~ /^[0-9]+([.][0-9]+)?$/) { print "N/A"; exit }
    if (kb >= 1024 * 1024) printf "%.2f GiB", kb/(1024*1024)
    else if (kb >= 1024) printf "%.2f MiB", kb/1024
    else printf "%.0f KiB", kb
  }'
}

format_cpu() {
  awk -v value="${1-}" 'BEGIN {
    if (value == "" || value !~ /^[0-9]+([.][0-9]+)?$/) { print "N/A"; exit }
    printf "%.2f%%", value
  }'
}

sample_mihomo_rss() {
  [[ -n "$MIHOMO_PID" ]] || return 0
  ps -o rss= -p "$MIHOMO_PID" 2>/dev/null | awk 'NR == 1 && $1 ~ /^[0-9]+$/ {print $1}'
}

sample_mihomo_cpu_ticks() {
  [[ -n "$MIHOMO_PID" && -r "/proc/$MIHOMO_PID/stat" ]] || return 0
  awk '{print $14 + $15}' "/proc/$MIHOMO_PID/stat" 2>/dev/null
}

monotonic_seconds() {
  [[ -r /proc/uptime ]] || return 0
  awk '{print $1}' /proc/uptime 2>/dev/null
}

# Run iperf3 while sampling the selected mihomo process' resident memory.
# A missing process (or an unusually short test) leaves the value as N/A
# rather than failing the benchmark.
run_iperf() {
  local memory_file="$1" cpu_file="$2"
  shift 2
  local pid rss peak=0 status start_ticks end_ticks start_time end_time clock_ticks cpu_percent=""
  : > "$memory_file"
  : > "$cpu_file"
  start_ticks="$(sample_mihomo_cpu_ticks)"
  start_time="$(monotonic_seconds)"
  "$@" &
  pid=$!
  rss="$(sample_mihomo_rss)"
  [[ "$rss" =~ ^[0-9]+$ ]] && peak="$rss"
  while kill -0 "$pid" 2>/dev/null; do
    rss="$(sample_mihomo_rss)"
    if [[ "$rss" =~ ^[0-9]+$ ]] && ((rss > peak)); then peak=$rss; fi
    sleep 0.05
  done
  wait "$pid"
  status=$?
  end_ticks="$(sample_mihomo_cpu_ticks)"
  end_time="$(monotonic_seconds)"
  clock_ticks="$(getconf CLK_TCK 2>/dev/null || true)"
  if [[ "$start_ticks" =~ ^[0-9]+([.][0-9]+)?$ && "$end_ticks" =~ ^[0-9]+([.][0-9]+)?$ &&
        "$start_time" =~ ^[0-9]+([.][0-9]+)?$ && "$end_time" =~ ^[0-9]+([.][0-9]+)?$ &&
        "$clock_ticks" =~ ^[1-9][0-9]*$ ]]; then
    cpu_percent="$(awk -v begin_ticks="$start_ticks" -v finish_ticks="$end_ticks" \
      -v begin_time="$start_time" -v finish_time="$end_time" -v hz="$clock_ticks" \
      'BEGIN { elapsed=finish_time-begin_time; if (elapsed > 0) printf "%.6f", (finish_ticks-begin_ticks)*100/(hz*elapsed) }')"
  fi
  if [[ -n "$MIHOMO_PID" && "$peak" -gt 0 ]]; then
    printf '%s\n' "$peak" > "$memory_file"
  else
    : > "$memory_file"
  fi
  printf '%s\n' "$cpu_percent" > "$cpu_file"
  return "$status"
}

trigger_mihomo_gc() {
  local label="$1"
  if ! curl --fail --silent --show-error --request PUT "$CONTROLLER_URL/debug/gc" >/dev/null; then
    echo "Warning: failed to trigger mihomo GC after $label via $CONTROLLER_URL/debug/gc" >&2
    GC_FAILURES=$((GC_FAILURES + 1))
  fi
}

parse_result() {
  local file="$1" protocol="$2" reverse="$3" bps jitter loss retrans error
  if [[ "$PARSER" == jq ]]; then
    error="$(jq -r '.error // empty' "$file" 2>/dev/null)"
    if [[ "$protocol" == TCP ]]; then
      bps="$(jq -r --argjson r "$reverse" 'if $r then (.end.sum_received.bits_per_second // 0) else (.end.sum_sent.bits_per_second // 0) end' "$file" 2>/dev/null)"
      retrans="$(jq -r 'if .end.sum_sent.retransmits != null then .end.sum_sent.retransmits elif .end.sum_received.retransmits != null then .end.sum_received.retransmits elif ([.end.streams[]?.sender.retransmits] | length) > 0 then ([.end.streams[]?.sender.retransmits] | add) else "N/A" end' "$file" 2>/dev/null)"
    else
      bps="$(jq -r '(.end.sum_received.bits_per_second // .end.sum.bits_per_second // 0)' "$file" 2>/dev/null)"
      jitter="$(jq -r '(.end.sum_received.jitter_ms // .end.sum.jitter_ms // 0)' "$file" 2>/dev/null)"
      loss="$(jq -r '(.end.sum_received.lost_percent // .end.sum.lost_percent // 0)' "$file" 2>/dev/null)"
    fi
  else
    read -r bps jitter loss retrans error < <(python3 - "$file" "$protocol" "$reverse" <<'PY'
import json, sys
try:
    d=json.load(open(sys.argv[1], encoding='utf-8'))
    protocol, reverse=sys.argv[2], sys.argv[3]=='1'
    if d.get('error'): print('0 0 0 0 '+str(d['error']).replace(' ','_')); raise SystemExit
    e=d.get('end',{}); s=e.get('sum_received') or e.get('sum') or {}
    sent=e.get('sum_sent',{}); received=e.get('sum_received',{})
    b=(received if reverse else sent).get('bits_per_second',0) if protocol=='TCP' else s.get('bits_per_second',0)
    r=(sent.get('retransmits') if sent.get('retransmits') is not None else received.get('retransmits')) if protocol=='TCP' else 0
    if protocol=='TCP' and r is None:
        stream_values=[st.get('sender',{}).get('retransmits') for st in e.get('streams',[]) if st.get('sender',{}).get('retransmits') is not None]
        r=sum(stream_values) if stream_values else 'N/A'
    print(b, s.get('jitter_ms',0), s.get('lost_percent',0), r)
except Exception as exc: print('0 0 0 0 '+str(exc).replace(' ','_'))
PY
    )
  fi
  [[ -n "${error:-}" ]] && { PARSE_ERROR="$error"; return 1; }
  [[ "$bps" =~ ^[0-9]+([.][0-9]+)?$ ]] || { PARSE_ERROR="invalid JSON throughput: ${bps:-empty}"; return 1; }
  printf '%s\t%s\t%s\t%s\n' "$bps" "${jitter:-}" "${loss:-}" "${retrans:-}"
}

run_test() {
  local protocol="$1" direction="$2" streams="$3" rate="$4" reverse=0 label file errfile memory_file cpu_file output bps jitter loss retrans memory_kb cpu_percent command_status
  PARSE_ERROR=""
  [[ "$direction" == reverse ]] && reverse=1
  label="$protocol $direction"
  [[ "$protocol" == TCP ]] && label="$label P=$streams" || label="$label $rate"
  file="$TMP_DIR/test-$(( ${#RESULTS[@]} + 1 )).json"
  errfile="$file.err"
  memory_file="$file.memory"
  cpu_file="$file.cpu"
  local args=(iperf3 "${IPERF_ARGS[@]}" -c "$SERVER" -p "$PORT" -t "$DURATION" -J)
  [[ "$reverse" == 1 ]] && args+=(-R)
  if [[ "$protocol" == TCP ]]; then args+=(-P "$streams"); else args+=(-u -b "$rate"); fi
  printf 'Running %-20s ...\n' "$label"
  run_iperf "$memory_file" "$cpu_file" "${args[@]}" >"$file" 2>"$errfile"
  command_status=$?
  memory_kb="$(<"$memory_file")"
  cpu_percent="$(<"$cpu_file")"
  trigger_mihomo_gc "$label"
  # Prefer a valid JSON result over the process exit code. Some Windows/Cygwin
  # iperf3 builds can return non-zero after the server has completed the test.
  if [[ -s "$file" ]] && output="$(parse_result "$file" "$protocol" "$reverse")"; then
    IFS=$'\t' read -r bps jitter loss retrans <<< "$output"
    [[ "$protocol" == TCP && -z "$retrans" ]] && retrans="N/A"
    RESULTS+=("$label|$(format_number "$bps")|$(format_decimal "$jitter")|$(format_decimal "$loss")|${retrans:--}|$(format_memory "$memory_kb")|$(format_cpu "$cpu_percent")|OK")
    printf '  %-24s effective_throughput=%-14s mihomo_memory=%-10s mihomo_cpu=%-8s' "$label" "$(format_number "$bps")" "$(format_memory "$memory_kb")" "$(format_cpu "$cpu_percent")"
    [[ "$protocol" == TCP ]] && printf ' retransmits=%s' "${retrans:--}"
    [[ "$protocol" == UDP ]] && printf ' jitter=%-7sms loss=%s%%' "$(format_decimal "$jitter")" "$(format_decimal "$loss")"
    echo " status=OK"
    if awk -v value="$bps" -v best="$BEST_BPS" 'BEGIN { exit !(value > best) }'; then
      BEST_BPS="$bps"
      BEST_LABEL="$label"
    fi
    if [[ "$protocol" == UDP ]] && [[ -z "$UDP_LOSS_ALERT" ]] && awk -v value="$loss" 'BEGIN { exit !(value > 1) }'; then
      UDP_LOSS_ALERT="$label ($(format_decimal "$loss")%)"
    fi
  else
    RESULTS+=("$label|-|-|-|-|$(format_memory "$memory_kb")|$(format_cpu "$cpu_percent")|FAILED")
    FAILURES=$((FAILURES + 1))
    [[ $command_status -ne 0 && -z "${PARSE_ERROR:-}" ]] && PARSE_ERROR="iperf3 exit code $command_status"
    printf '  %-24s status=FAILED' "$label"
    [[ -n "${PARSE_ERROR:-}" ]] && printf ' (%s)' "$PARSE_ERROR"
    if [[ -s "$errfile" ]]; then
      printf ' (%s)' "$(tr '\n' ' ' < "$errfile" | sed 's/[[:space:]]\+/ /g; s/^ //; s/ $//')"
    fi
    echo
  fi
}

echo "iperf3 LAN benchmark: $SERVER:$PORT (IPv4, ${DURATION}s per test)"
IFS=',' read -r -a PARALLEL <<< "$PARALLEL_CSV"
IFS=',' read -r -a RATES <<< "$UDP_RATES_CSV"
for streams in "${PARALLEL[@]}"; do run_test TCP forward "$streams" ""; run_test TCP reverse "$streams" ""; done
for rate in "${RATES[@]}"; do run_test UDP forward 1 "$rate"; run_test UDP reverse 1 "$rate"; done

echo
printf '%-24s %-14s %-12s %-10s %-12s %-10s %-10s %s\n' "TEST" "EFFECTIVE_BPS" "JITTER(ms)" "LOSS(%)" "RETRANSMITS" "MIHOMO_RSS" "MIHOMO_CPU" "STATUS"
printf '%-24s %-14s %-12s %-10s %-12s %-10s %-10s %s\n' "------------------------" "--------------" "------------" "----------" "------------" "----------" "----------" "------"
for row in "${RESULTS[@]}"; do IFS='|' read -r a b c d e f g h <<< "$row"; printf '%-24s %-14s %-12s %-10s %-12s %-10s %-10s %s\n' "$a" "$b" "$c" "$d" "$e" "$f" "$g" "$h"; done
if [[ -n "$BEST_LABEL" ]]; then echo; echo "最高有效吞吐: $BEST_LABEL ($(format_number "$BEST_BPS"))"; fi
if [[ -n "$UDP_LOSS_ALERT" ]]; then echo "UDP 丢包超过 1% 的首个档位: $UDP_LOSS_ALERT"; else echo "UDP 丢包未超过 1%。"; fi
((FAILURES == 0)) || { echo; echo "$FAILURES test(s) failed." >&2; exit 1; }
((GC_FAILURES == 0)) || { echo; echo "Failed to trigger mihomo GC after $GC_FAILURES test(s)." >&2; exit 1; }
echo; echo "All tests completed successfully."
