#!/usr/bin/env bash
# Claude Code Statusline - Catppuccin Mocha Blue
#
# Shows: model | context-window bar (real session size from Claude Code's
# stdin, with an Anthropic /v1/models fallback — no hardcoding) | git branch/PR/diffstat |
# 5h and 7-day usage-limit bars with reset countdowns.
# Responsive: single line when wide enough, two lines when narrow.
#
# Setup:
#   1. Save this file as ~/.claude/statusline-command.sh
#   2. chmod +x ~/.claude/statusline-command.sh
#   3. Add to ~/.claude/settings.json:
#        "statusLine": { "type": "command", "command": "bash ~/.claude/statusline-command.sh" }
#   4. Needs `jq` and `curl`. Reads your Claude Code OAuth token from the
#      macOS Keychain ("Claude Code-credentials") or, on Linux,
#      ~/.claude/.credentials.json — same credentials Claude Code itself
#      already uses, nothing extra to configure.

input=$(cat)

# -- Colors --
c_blue=$'\x1b[38;2;137;180;250m'
c_sapphire=$'\x1b[38;2;116;199;236m'
c_lavender=$'\x1b[38;2;180;190;254m'
c_subtext=$'\x1b[38;2;166;173;200m'
c_overlay=$'\x1b[38;2;108;112;134m'
c_green=$'\x1b[38;2;166;227;161m'
c_yellow=$'\x1b[38;2;249;226;175m'
c_peach=$'\x1b[38;2;250;179;135m'
c_red=$'\x1b[38;2;243;139;168m'
c_mauve=$'\x1b[38;2;203;166;247m'
c_claude=$'\x1b[38;2;217;119;87m'   # Claude brand coral (#D97757)
c_rst=$'\x1b[0m'
c_bold=$'\x1b[1m'

icon_model="✳"   # Claude glyph (static — animating it looks jumpy at CC's 300ms refresh)

COLS=$(tput cols 2>/dev/null || echo 120)
SEP_PLAIN=" | "
SEP="${c_overlay}${SEP_PLAIN}${c_rst}"

# Strip ANSI escapes then count chars for visible width measurement.
# Emoji display as 2 columns but count as 1 char — we correct with +EMOJI_BONUS.
strip_ansi() { printf '%s' "$1" | sed $'s/\x1b\\[[0-9;]*m//g'; }
vis_width()  { printf '%s' "$(strip_ansi "$1")" | wc -m | tr -d ' '; }

# Print non-empty segments joined by SEP.
print_line() {
  local first=1
  for seg in "$@"; do
    [ -z "$seg" ] && continue
    [ "$first" -eq 0 ] && printf '%s' "$SEP"
    printf '%s' "$seg"
    first=0
  done
}

# -- Parse JSON --
model=$(echo "$input" | jq -r '.model.display_name // "Claude"')
dir=$(echo "$input"   | jq -r '.workspace.current_dir // ""')
dirname=$(basename "$dir")
model_id=$(echo "$input" | jq -r '.model.id // ""')
used_pct=$(echo "$input" | jq -r '.context_window.used_percentage // empty')
in_tok=$(echo "$input"  | jq -r '.context_window.total_input_tokens // empty')
out_tok=$(echo "$input" | jq -r '.context_window.total_output_tokens // empty')
# Claude Code sends the real per-session window here (reflects [1m] / beta
# expansions the /v1/models catalog does not). Authoritative when present.
ctx_size_stdin=$(echo "$input" | jq -r '.context_window.context_window_size // empty')

# -- Model segment --
seg_model="${c_claude}${c_bold}${icon_model} ${model}${c_rst}"

# -- OAuth token (macOS keychain / linux credentials file) --
IS_MAC=false; [ "$(uname)" = "Darwin" ] && IS_MAC=true
get_token() {
  local creds=""
  if [ "$IS_MAC" = true ]; then
    creds=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null)
  else
    creds=$(cat ~/.claude/.credentials.json 2>/dev/null)
  fi
  [ -z "$creds" ] && return 1
  echo "$creds" | jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null
}

# -- Real context window size --
# 1) Prefer the value Claude Code passes on stdin (context_window_size). This
#    reflects the actual session window, including [1m] / beta expansions that
#    the /v1/models catalog does not advertise. Fully dynamic, no network call.
# 2) Fall back to Anthropic's /v1/models (max_input_tokens) for older CC builds
#    that don't send the field. 3) Last resort: 200k.
CTX_WINDOW=200000
if [ -n "$ctx_size_stdin" ]; then
  CTX_WINDOW="$ctx_size_stdin"
else
MODELS_CACHE="/tmp/claude-statusline-models.json"
MODELS_CACHE_AGE=21600  # 6h; the model catalog barely changes
models_json=""
if [ -f "$MODELS_CACHE" ]; then
  if [ "$IS_MAC" = true ]; then m_mtime=$(stat -f %m "$MODELS_CACHE" 2>/dev/null)
  else m_mtime=$(stat -c %Y "$MODELS_CACHE" 2>/dev/null); fi
  m_now=$(date +%s)
  if [ -n "$m_mtime" ] && [ $((m_now - m_mtime)) -lt $MODELS_CACHE_AGE ]; then
    models_json=$(cat "$MODELS_CACHE" 2>/dev/null)
  fi
fi
if [ -z "$models_json" ]; then
  token=$(get_token)
  if [ -n "$token" ]; then
    resp=$(curl -s --max-time 5 "https://api.anthropic.com/v1/models?limit=1000" \
      -H "Authorization: Bearer $token" \
      -H "anthropic-beta: oauth-2025-04-20" \
      -H "anthropic-version: 2023-06-01")
    if echo "$resp" | jq -e '.data' >/dev/null 2>&1; then
      models_json="$resp"
      echo "$resp" > "$MODELS_CACHE" 2>/dev/null
    elif [ -f "$MODELS_CACHE" ]; then
      models_json=$(cat "$MODELS_CACHE" 2>/dev/null)
    fi
  fi
fi
if [ -n "$models_json" ] && [ -n "$model_id" ]; then
  looked_up=$(echo "$models_json" | jq -r --arg id "$model_id" \
    '.data[] | select(.id == $id) | .max_input_tokens // empty' 2>/dev/null)
  [ -n "$looked_up" ] && CTX_WINDOW="$looked_up"
fi
fi

# -- Context bar segment --
seg_ctx=""
if [ -n "$used_pct" ]; then
  used=${used_pct%.*}
  [ "$used" -gt 100 ] && used=100
  if   [ "$used" -lt 50 ]; then ctx_c="$c_green"
  elif [ "$used" -lt 70 ]; then ctx_c="$c_yellow"
  elif [ "$used" -lt 90 ]; then ctx_c="$c_peach"
  else ctx_c="$c_red"; fi
  # Fractional bar: 8 cells × 8 eighths = 64 steps, so even 1-2% shows a sliver.
  # Filled part in the usage color, empty part dim so the fill is always visible.
  BAR_W=8
  eighths=$(( used * BAR_W * 8 / 100 ))
  [ "$eighths" -eq 0 ] && [ "$used" -gt 0 ] && eighths=1   # always show a sliver if used
  bar=""
  for ((i=0; i<BAR_W; i++)); do
    ce=$(( eighths - i*8 ))
    if   [ "$ce" -ge 8 ]; then bar="${bar}${ctx_c}█"
    elif [ "$ce" -le 0 ]; then bar="${bar}${c_overlay}░"
    else
      case $ce in
        1) g="▏";; 2) g="▎";; 3) g="▍";; 4) g="▌";;
        5) g="▋";; 6) g="▊";; 7) g="▉";;
      esac
      bar="${bar}${ctx_c}${g}"
    fi
  done
  bar="${bar}${c_rst}"
  fmt_tok() {
    local t=$1
    if [ "$t" -ge 1000000 ]; then
      awk -v n="$t" 'BEGIN{printf "%.1fM", n/1000000}'
    else
      echo "$(( t / 1000 ))k"
    fi
  }
  tok_str=""
  if [ -n "$in_tok" ] && [ -n "$out_tok" ]; then
    tok_used=$(( in_tok + out_tok ))
    tok_str=" $(fmt_tok "$tok_used")/$(fmt_tok "$CTX_WINDOW")"
  fi
  seg_ctx="${bar} ${ctx_c}${used}%${tok_str}${c_rst}"
fi

# -- Rate limit helpers --
color_for_pct() {
  if   [ "$1" -lt 50 ]; then echo "$c_green"
  elif [ "$1" -lt 75 ]; then echo "$c_yellow"
  elif [ "$1" -lt 90 ]; then echo "$c_peach"
  else echo "$c_red"; fi
}

fmt_reset() {
  local target=${1%.*} now diff d h m
  now=$(date +%s); diff=$(( target - now ))
  [ "$diff" -le 0 ] && { echo "now"; return; }
  d=$(( diff / 86400 )); h=$(( (diff % 86400) / 3600 )); m=$(( (diff % 3600) / 60 ))
  if   [ "$d" -gt 0 ]; then echo "${d}d ${h}h"
  elif [ "$h" -gt 0 ]; then echo "${h}h ${m}m"
  else echo "${m}m"; fi
}

# -- Fetch 5h/7d usage from the OAuth usage API (CC does not pass this via stdin) --
# Cached to /tmp for 180s to avoid hammering the API / getting rate-limited.
USAGE_CACHE="/tmp/claude-statusline-usage.json"
USAGE_CACHE_AGE=180

usage_json=""
if [ -f "$USAGE_CACHE" ]; then
  if [ "$IS_MAC" = true ]; then cache_mtime=$(stat -f %m "$USAGE_CACHE" 2>/dev/null)
  else cache_mtime=$(stat -c %Y "$USAGE_CACHE" 2>/dev/null); fi
  now_epoch=$(date +%s)
  if [ -n "$cache_mtime" ] && [ $((now_epoch - cache_mtime)) -lt $USAGE_CACHE_AGE ]; then
    usage_json=$(cat "$USAGE_CACHE" 2>/dev/null)
  fi
fi
if [ -z "$usage_json" ]; then
  token=$(get_token)
  if [ -n "$token" ]; then
    resp=$(curl -s --max-time 5 "https://api.anthropic.com/api/oauth/usage" \
      -H "Authorization: Bearer $token" \
      -H "anthropic-beta: oauth-2025-04-20" \
      -H "Content-Type: application/json")
    if echo "$resp" | jq -e '.five_hour' >/dev/null 2>&1; then
      usage_json="$resp"
      echo "$resp" > "$USAGE_CACHE" 2>/dev/null
    elif [ -f "$USAGE_CACHE" ]; then
      usage_json=$(cat "$USAGE_CACHE" 2>/dev/null)
    fi
  fi
fi

# ISO8601 UTC -> epoch (BSD/GNU date compatible)
iso_to_epoch() {
  local iso
  iso=$(echo "$1" | sed -E 's/\.[0-9]+//; s/\+00:00$/+0000/; s/Z$/+0000/')
  if [ "$IS_MAC" = true ]; then date -juf "%Y-%m-%dT%H:%M:%S%z" "$iso" +%s 2>/dev/null
  else date -d "$iso" +%s 2>/dev/null; fi
}

# -- 5h rate limit segment --
seg_5h=""
seg_7d=""
if [ -n "$usage_json" ]; then
  five_h=$(echo "$usage_json" | jq -r '.five_hour.utilization // empty')
  if [ -n "$five_h" ]; then
    five_h_int=${five_h%.*}
    lim_c=$(color_for_pct "$five_h_int")
    reset_iso=$(echo "$usage_json" | jq -r '.five_hour.resets_at // empty')
    seg_5h="${lim_c}5h: ${five_h_int}%${c_rst}"
    if [ -n "$reset_iso" ]; then
      reset_epoch=$(iso_to_epoch "$reset_iso")
      [ -n "$reset_epoch" ] && seg_5h+=" ${c_overlay}($(fmt_reset "$reset_epoch"))${c_rst}"
    fi
  fi

  # -- 7d rate limit segment --
  seven_d=$(echo "$usage_json" | jq -r '.seven_day.utilization // empty')
  if [ -n "$seven_d" ]; then
    seven_d_int=${seven_d%.*}
    lim_c=$(color_for_pct "$seven_d_int")
    reset_iso=$(echo "$usage_json" | jq -r '.seven_day.resets_at // empty')
    seg_7d="${lim_c}7d: ${seven_d_int}%${c_rst}"
    if [ -n "$reset_iso" ]; then
      reset_epoch=$(iso_to_epoch "$reset_iso")
      [ -n "$reset_epoch" ] && seg_7d+=" ${c_overlay}($(fmt_reset "$reset_epoch"))${c_rst}"
    fi
  fi
fi

# -- Layout decision --
# Line 1 (primary): model | context bar
# Line 2 (secondary): rate limits
# Measure total visible width of all segments; use two lines if it won't fit.
ALL=("$seg_model" "$seg_ctx" "$seg_5h" "$seg_7d")
total_vis=0; count=0
for seg in "${ALL[@]}"; do
  [ -z "$seg" ] && continue
  total_vis=$(( total_vis + $(vis_width "$seg") ))
  count=$(( count + 1 ))
done
# Add separator widths (3 chars each) + emoji double-width correction (4 emoji max)
[ "$count" -gt 1 ] && total_vis=$(( total_vis + (count - 1) * ${#SEP_PLAIN} ))
total_vis=$(( total_vis + 4 ))

if [ "$total_vis" -le "$COLS" ]; then
  print_line "${ALL[@]}"
else
  print_line "$seg_model" "$seg_ctx"
  echo ""
  print_line "$seg_5h" "$seg_7d"
fi
