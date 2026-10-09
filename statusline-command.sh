#!/bin/bash
# Claude Code statusLine script.
# Renders chips for model/dir, git branch, context usage, and rate limits.
# Falls back to a stacked (one-chip-per-line) layout when the chips would
# not fit on a single line in the current terminal width.

input=$(cat)

# Hand the rate limits to cc-meter (~/Dev/flash-cc-meter), so it can show them
# without polling the rate-limited usage API. Atomic write: tmp file + mv.
cc_meter_dir="$HOME/.cache/cc-meter"
if mkdir -p "$cc_meter_dir" 2>/dev/null; then
  rl=$(echo "$input" | jq -c '.rate_limits // empty' 2>/dev/null)
  if [ -n "$rl" ]; then
    printf '%s\n' "$rl" > "$cc_meter_dir/statusline.json.$$" && mv "$cc_meter_dir/statusline.json.$$" "$cc_meter_dir/statusline.json"
  fi
fi

model=$(echo "$input" | jq -r '.model.display_name // empty')
dir=$(echo "$input" | jq -r '.workspace.current_dir // empty')
cwd=$(basename "$dir")
style=$(echo "$input" | jq -r '.output_style.name // empty')

branch=$(git -C "$dir" --no-optional-locks branch --show-current 2>/dev/null)
dirty=""
if [ -n "$branch" ]; then
  changes=$(git -C "$dir" --no-optional-locks status --porcelain 2>/dev/null)
  [ -n "$changes" ] && dirty="*"
fi

used=$(echo "$input" | jq -r '.context_window.used_percentage // empty')

# Throughput, as a rolling window over the last TPS_WINDOW responses: summed
# output tokens over summed end-to-end time (NOT a mean of per-response rates —
# that would let one short reply dominate). End-to-end means the number includes
# time-to-first-token and thinking, so it reads lower than raw decode speed, and
# the window is what keeps it steady: per-response it swings 30-70, at window 8
# it sits inside a ~6 tok/s band. Falls back to the session average from
# cost/context_window when the transcript has fewer than TPS_WINDOW responses.
api_ms=$(echo "$input" | jq -r '.cost.total_api_duration_ms // empty')
out_tok=$(echo "$input" | jq -r '.context_window.total_output_tokens // empty')
tps_avg=""
if [ -n "$api_ms" ] && [ -n "$out_tok" ] && [ "$api_ms" -gt 0 ] 2>/dev/null; then
  tps_avg=$(awk -v t="$out_tok" -v m="$api_ms" 'BEGIN{printf "%.0f", t/(m/1000)}')
fi

transcript=$(echo "$input" | jq -r '.transcript_path // empty')
# Rolling throughput over TPS_WINDOW responses and rolling median latency over
# LAT_WINDOW. One python pass computes both — two would double the per-render cost.
TPS_WINDOW=${TPS_WINDOW:-8}
LAT_WINDOW=${LAT_WINDOW:-12}
tps_last=""
lat_med=""
if [ -n "$transcript" ] && [ -f "$transcript" ]; then
  read -r tps_last lat_med <<<"$(tail -n 800 "$transcript" | TPS_WINDOW="$TPS_WINDOW" LAT_WINDOW="$LAT_WINDOW" python3 -c '
import sys, os, json, statistics, datetime
def t(s): return datetime.datetime.fromisoformat(s.replace("Z", "+00:00"))
tps_w, lat_w = int(os.environ["TPS_WINDOW"]), int(os.environ["LAT_WINDOW"])
prompts, blocks = [], {}
for line in sys.stdin:
    try: d = json.loads(line)
    except Exception: continue
    ty = d.get("type")
    if ty in ("user", "system") and not d.get("isMeta"):
        prompts.append(t(d["timestamp"]))
    elif ty == "assistant" and d.get("requestId"):
        u = (d.get("message") or {}).get("usage") or {}
        blocks.setdefault(d["requestId"], []).append((t(d["timestamp"]), u.get("output_tokens") or 0))
rates, lats = [], []
for rid, v in blocks.items():
    first, end, out = min(x[0] for x in v), max(x[0] for x in v), v[0][1]
    starts = [p for p in prompts if p < first]
    if not starts or not out: continue
    begin = max(starts)
    lat, dt = (first - begin).total_seconds(), (end - begin).total_seconds()
    # An idle session between turns is not generation time, so drop absurd gaps.
    if not (0 < dt < 600): continue
    rates.append((out, dt)); lats.append(lat)
win = rates[-tps_w:]
tps = f"{sum(o for o, _ in win) / sum(d for _, d in win):.0f}" if win else "-"
lat = f"{statistics.median(lats[-lat_w:]):.1f}" if lats else "-"
print(tps, lat)
' 2>/dev/null)"
  [ "$tps_last" = "-" ] && tps_last=""
  [ "$lat_med" = "-" ] && lat_med=""
fi

cache_hit=$(echo "$input" | jq -r '.prompt_cache.hit_ratio // empty')

five=$(echo "$input" | jq -r '.rate_limits.five_hour.used_percentage // empty')
five_reset_epoch=$(echo "$input" | jq -r '.rate_limits.five_hour.resets_at // empty')
five_reset=""
if [ -n "$five_reset_epoch" ]; then
  five_reset=$(date -r "$five_reset_epoch" +%H:%M 2>/dev/null)
fi

week=$(echo "$input" | jq -r '.rate_limits.seven_day.used_percentage // empty')
week_reset_epoch=$(echo "$input" | jq -r '.rate_limits.seven_day.resets_at // empty')
week_reset=""
if [ -n "$week_reset_epoch" ]; then
  week_reset=$(date -r "$week_reset_epoch" '+%b %d %H:%M' 2>/dev/null)
fi

# chip <bg-R> <bg-G> <bg-B> <fg-R> <fg-G> <fg-B> <label text>
# Uses 24-bit truecolor (not 256-color indices) so hues render consistently
# regardless of the terminal's color profile/remapping.
# Wraps the label in Powerline Extra Symbols rounded end-caps
# (U+E0B6 / U+E0B4) colored as the chip's own background against the
# default terminal background, so each chip reads as a rounded "pill".
# Requires a Nerd Font (or a font patched with Powerline Extra Symbols) —
# without one these render as tofu/boxes.
chip() {
  bg_r="$1"; bg_g="$2"; bg_b="$3"; fg_r="$4"; fg_g="$5"; fg_b="$6"; txt="$7"
  printf '\033[1;38;2;%d;%d;%dm\xee\x82\xb6\033[0m\033[1;38;2;%d;%d;%d;48;2;%d;%d;%dm %s \033[0m\033[1;38;2;%d;%d;%dm\xee\x82\xb4\033[0m' \
    "$bg_r" "$bg_g" "$bg_b" \
    "$fg_r" "$fg_g" "$fg_b" "$bg_r" "$bg_g" "$bg_b" \
    "$txt" \
    "$bg_r" "$bg_g" "$bg_b"
}

sep="$(printf '\033[38;5;244m | \033[0m')"

# Parallel arrays: colored chip strings and their plain-text labels
# (labels are used only to measure visible width, no ANSI in them).
chips=()
labels=()

add() {
  chips+=("$1")
  labels+=("$2")
}

# RGB triplets below are the true-color equivalents of the original
# 256-color indices, so the intended neon hues render consistently:
#   33  (electric blue)   -> 0,135,255
#   118 (neon lime)       -> 95,255,0
#   51  (neon cyan)       -> 0,255,255
#   202 (orange-red)      -> 255,95,0
#   226 (neon yellow)     -> 255,255,0
#   208 (orange)          -> 255,135,0
# Foreground is pure white (255,255,255) or pure black (0,0,0), chosen per
# background for contrast (matches the original 97/30 SGR choices).

add "$(chip 0 135 255 255 255 255 "${model} · ${cwd}")" "${model} · ${cwd}"

if [ -n "$branch" ]; then
  add "$(chip 95 255 0 0 0 0 "${branch}${dirty}")" "${branch}${dirty}"
fi

if [ -n "$used" ]; then
  used_label="ctx: $(printf '%.0f' "$used")%"
  add "$(chip 0 255 255 0 0 0 "$used_label")" "$used_label"
fi

if [ -n "$tps_last" ] || [ -n "$tps_avg" ]; then
  tps_label="${tps_last:-$tps_avg} tok/s"
  # Latency is the wait before the first block of the answer lands — NOT TTFT,
  # which Claude Code exposes only over OpenTelemetry. It bounds TTFT from above.
  [ -n "$lat_med" ] && tps_label="${tps_label} · lat ${lat_med}s"
  # 205 (hot pink)
  add "$(chip 255 95 175 0 0 0 "$tps_label")" "$tps_label"
fi

if [ -n "$cache_hit" ]; then
  cache_label="cache: $(awk -v r="$cache_hit" 'BEGIN{printf "%.0f", r*100}')%"
  # 79 (steel blue)
  add "$(chip 95 175 175 0 0 0 "$cache_label")" "$cache_label"
fi

if [ -n "$five" ]; then
  five_label="5h limit: $(printf '%.0f' "$five")%"
  if [ -n "$five_reset" ]; then
    five_label="${five_label} (resets ${five_reset})"
  fi
  add "$(chip 255 95 0 0 0 0 "$five_label")" "$five_label"
fi

if [ -n "$week" ]; then
  week_label="weekly limit: $(printf '%.0f' "$week")%"
  if [ -n "$week_reset" ]; then
    week_label="${week_label} (resets ${week_reset})"
  fi
  add "$(chip 255 255 0 0 0 0 "$week_label")" "$week_label"
fi

if [ -n "$style" ] && [ "$style" != "default" ]; then
  add "$(chip 255 135 0 0 0 0 "$style")" "$style"
fi

# Detect terminal width: tput cols -> $COLUMNS -> 80.
# statusLine commands may run without a real tty attached, so tput cols
# can fail or print nothing; guard against that and any non-numeric value.
cols=$(tput cols 2>/dev/null)
if ! [[ "$cols" =~ ^[0-9]+$ ]]; then
  cols="$COLUMNS"
fi
if ! [[ "$cols" =~ ^[0-9]+$ ]]; then
  cols=80
fi

# Compute total visible width of the single-line rendering: each chip is
# "label" padded with one space on each side plus a half-circle end-cap on
# each side (see chip()), joined by the 3-char " | " separator.
n=${#labels[@]}
total=0
for label in "${labels[@]}"; do
  total=$((total + ${#label} + 2 + 2))
done
if [ "$n" -gt 1 ]; then
  total=$((total + (n - 1) * 3))
fi

if [ "$total" -le "$cols" ]; then
  out=""
  for c in "${chips[@]}"; do
    if [ -n "$out" ]; then
      out="${out}${sep}${c}"
    else
      out="$c"
    fi
  done
  printf "%s\n" "$out"
else
  # Too wide for one line: stack one chip per line so nothing overflows
  # or gets cut off, regardless of how narrow the terminal is.
  for c in "${chips[@]}"; do
    printf "%s\n" "$c"
  done
fi
