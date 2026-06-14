#!/usr/bin/env bash
#
# claude-clack — a Claude Code hook that plays keyboard sounds as Claude works.
# Sound type is chosen by the hook event that invoked it:
#   • typing — a clack burst after a successful edit   (PostToolUse)
#   • prompt — a quack when Claude asks for your input (Notification)
# Every hook entry is registered with "async": true, so Claude Code does not wait
# for us — it runs this script in the background to completion. We therefore play
# everything synchronously inline; no re-exec / detach is needed. All tuning lives
# in settings.json next to this script.

# A hook must never change the tool's exit status; nothing below is allowed to fail.
set +e

SOURCE="${BASH_SOURCE[0]}"
while [ -h "$SOURCE" ]; do
  DIR="$(cd -P "$(dirname "$SOURCE")" >/dev/null 2>&1 && pwd)"
  SOURCE="$(readlink "$SOURCE")"
  [ "${SOURCE:0:1}" = "/" ] || SOURCE="$DIR/$SOURCE"
done
SCRIPT_DIR="$(cd -P "$(dirname "$SOURCE")" >/dev/null 2>&1 && pwd)"
ASSETS_DIR="$SCRIPT_DIR/assets"
CONFIG="$SCRIPT_DIR/settings.json"

cfg() {
  local key="$1" def="$2" val
  [ -f "$CONFIG" ] || { printf '%s' "$def"; return; }
  val="$(sed -n 's/.*"'"$key"'"[[:space:]]*:[[:space:]]*"\{0,1\}\([^",}]*\)"\{0,1\}.*/\1/p' "$CONFIG" \
        | head -n1 | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  if [ -n "$val" ]; then printf '%s' "$val"; else printf '%s' "$def"; fi
}

intval() {
  case "$1" in ""|*[!0-9]*) printf '%s' "$2" ;; *) printf '%s' "$1" ;; esac
}

[ "$(cfg disable false)" = "true" ] && exit 0
VOLUME="$(cfg volume 0.5)"
CPC="$(intval "$(cfg chars_per_clack 12)" 12)"; [ "$CPC" -lt 1 ] && CPC=12
MIN="$(intval "$(cfg min 3)" 3)"
MAX="$(intval "$(cfg max 30)" 30)"
[ "$MAX" -lt "$MIN" ] && MAX="$MIN"
GAP_MIN="$(intval "$(cfg gap_min_ms 45)" 45)"
GAP_MAX="$(intval "$(cfg gap_max_ms 110)" 110)"
[ "$GAP_MAX" -lt "$GAP_MIN" ] && GAP_MAX="$GAP_MIN"
FIXED_COUNT="$(cfg count "")"

# aplay has no volume flag (ALSA uses the system mixer); `volume` is afplay-only.
if command -v afplay >/dev/null 2>&1; then
  PLAY_CMD=(afplay -v "$VOLUME")
elif command -v aplay >/dev/null 2>&1; then
  PLAY_CMD=(aplay -q)
else
  exit 0
fi

play_one() {
  [ -f "$1" ] && "${PLAY_CMD[@]}" "$1" </dev/null >/dev/null 2>&1
  exit 0
}

# nullglob isn't portable to macOS's bash 3.2, so guard the no-match case.
shopt -s nullglob 2>/dev/null
SOUNDS=("$ASSETS_DIR"/clack*.wav)
N="${#SOUNDS[@]}"

# Reject the top of $RANDOM's range so the modulo is unbiased when N ∤ 32768.
rand_below() {
  local n="$1" limit r
  limit=$(( 32768 - (32768 % n) ))
  r=$RANDOM
  while [ "$r" -ge "$limit" ]; do r=$RANDOM; done
  echo $(( r % n ))
}

# Drain stdin fully so the writer can't block.
EVENT="$(cat 2>/dev/null)"

# grep the FULL event and take the FIRST match: that's the genuine top-level
# hook_event_name, which precedes tool_input; any copy inside user edit text comes
# later and is JSON-escaped (so this pattern won't match it). A fixed-length prefix
# would misclassify when hook_event_name sits past it behind a large field.
EVENT_NAME="$(printf '%s' "$EVENT" \
  | grep -oEm1 '"hook_event_name"[[:space:]]*:[[:space:]]*"[^"]*"' \
  | sed -E 's/.*"([^"]*)"$/\1/')"

case "$EVENT_NAME" in
  Notification)
    # Quack only fires here for the notification types the matcher allows
    # (settings.json restricts this hook to permission_prompt).
    [ "$(cfg prompt_sound true)" = "true" ] && play_one "$ASSETS_DIR/quack.wav"
    exit 0 ;;
  PostToolUse|"") ;;
  *) exit 0 ;;
esac

if [ -n "$FIXED_COUNT" ] && [ -z "${FIXED_COUNT//[0-9]/}" ]; then
  COUNT="$FIXED_COUNT"
else
  # awk walks the JSON as data (no shell eval), summing inserted-text fields and
  # stopping early at MAX. The INPUT is bounded to an 8 KB prefix: the per-char scan
  # is slow, and a large non-wanted field (e.g. old_string/tool_response before
  # new_string) would otherwise be scanned in full. 8 KB covers the preamble + a
  # typical edit; past it we under-count.
  CAP=$(( (MAX + 1) * CPC ))
  CHARS="$(printf '%s' "${EVENT:0:8192}" | awk -v cap="$CAP" '
    function wanted(k) { return (k == "content" || k == "new_string" || k == "new_source") }
    { d = d $0 "\n" }
    END {
      n = length(d); instr = 0; esc = 0; curlen = 0; pending = 0; curkey = ""; total = 0
      for (i = 1; i <= n; i++) {
        c = substr(d, i, 1)
        if (instr) {
          if (esc)       { esc = 0; curlen++ }
          else if (c == "\\") { esc = 1; curlen++ }
          else if (c == "\"") { instr = 0; pending = 1; lastlen = curlen; laststr = buf; continue }
          else           { buf = buf c; curlen++ }
          if (wanted(curkey) && total + curlen >= cap) { print cap; exit }
          continue
        }
        if (c == "\"")      { instr = 1; buf = ""; curlen = 0; continue }
        if (c == " " || c == "\t" || c == "\n" || c == "\r") continue
        if (c == ":")       { if (pending) { curkey = laststr; pending = 0 }; continue }
        if (pending) {
          if (wanted(curkey)) { total += lastlen; if (total >= cap) { print total; exit } }
          pending = 0
        }
        curkey = ""
      }
      if (pending && wanted(curkey)) total += lastlen
      print total + 0
    }
  ' 2>/dev/null)"
  CHARS="$(intval "$CHARS" 0)"

  if [ "$CHARS" -gt 0 ]; then
    COUNT=$(( (CHARS + CPC / 2) / CPC ))
  else
    COUNT=$(( MIN + $(rand_below $(( MAX - MIN + 1 )) ) ))
  fi
  [ "$COUNT" -lt "$MIN" ] && COUNT="$MIN"
  [ "$COUNT" -gt "$MAX" ] && COUNT="$MAX"
fi
[ "$COUNT" -lt 1 ] && COUNT=1

# Play the clack burst synchronously: async hooks run to completion in the
# background, so blocking here for the ~1-2s burst doesn't stall Claude.
[ "$N" -gt 0 ] || exit 0
GAP_SPAN=$(( GAP_MAX - GAP_MIN + 1 ))
i=0
while [ "$i" -lt "$COUNT" ]; do
  SOUND="${SOUNDS[$(rand_below "$N")]}"
  [ -f "$SOUND" ] && "${PLAY_CMD[@]}" "$SOUND" </dev/null >/dev/null 2>&1 &
  i=$(( i + 1 ))
  if [ "$i" -lt "$COUNT" ]; then
    GAP_MS=$(( GAP_MIN + $(rand_below "$GAP_SPAN") ))
    sleep "$(printf '0.%03d' "$GAP_MS")"
  fi
done
wait
exit 0