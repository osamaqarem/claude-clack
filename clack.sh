#!/usr/bin/env bash
#
# claude-clack — a Claude Code PostToolUse hook that plays a keyboard-clack burst
# when Claude edits a file. Claude waits for the hook to exit, so it returns
# immediately and re-execs itself detached as a "burst worker". All tuning lives
# in settings.json next to this script.

# A hook must never change the tool's exit status; nothing below is allowed to fail.
set +e

MODE="${1:-}"

# Resolve our own directory (following symlinks) so we work regardless of cwd.
SOURCE="${BASH_SOURCE[0]}"
while [ -h "$SOURCE" ]; do
  DIR="$(cd -P "$(dirname "$SOURCE")" >/dev/null 2>&1 && pwd)"
  SOURCE="$(readlink "$SOURCE")"
  [ "${SOURCE:0:1}" = "/" ] || SOURCE="$DIR/$SOURCE"
done
SCRIPT_DIR="$(cd -P "$(dirname "$SOURCE")" >/dev/null 2>&1 && pwd)"
SELF="$SCRIPT_DIR/$(basename "$SOURCE")"
ASSETS_DIR="$SCRIPT_DIR/assets"
CONFIG="$SCRIPT_DIR/settings.json"

# cfg KEY DEFAULT -> value for KEY from the flat JSON settings.json, else DEFAULT.
cfg() {
  local key="$1" def="$2" val
  [ -f "$CONFIG" ] || { printf '%s' "$def"; return; }
  val="$(sed -n 's/.*"'"$key"'"[[:space:]]*:[[:space:]]*"\{0,1\}\([^",}]*\)"\{0,1\}.*/\1/p' "$CONFIG" \
        | head -n1 | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  if [ -n "$val" ]; then printf '%s' "$val"; else printf '%s' "$def"; fi
}

# intval VALUE DEFAULT -> VALUE if a non-negative integer, else DEFAULT.
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

# Player is auto-detected, not configurable. aplay has no volume flag (ALSA
# volume is the system mixer), so `volume` applies to afplay only.
if command -v afplay >/dev/null 2>&1; then
  PLAY_CMD=(afplay -v "$VOLUME")
elif command -v aplay >/dev/null 2>&1; then
  PLAY_CMD=(aplay -q)
else
  exit 0
fi

# nullglob isn't portable to macOS's bash 3.2, so guard the no-match case.
shopt -s nullglob 2>/dev/null
SOUNDS=("$ASSETS_DIR"/clack*.wav)
N="${#SOUNDS[@]}"
[ "$N" -gt 0 ] || exit 0

# Unbiased integer in [0, N): reject the top of $RANDOM's range so the modulo is
# uniform even when N does not divide 32768.
rand_below() {
  local n="$1" limit r
  limit=$(( 32768 - (32768 % n) ))
  r=$RANDOM
  while [ "$r" -ge "$limit" ]; do r=$RANDOM; done
  echo $(( r % n ))
}

# Worker mode: play the burst, then exit. Detached, so blocking here never delays
# Claude. The launcher passes the clack count as $2.
if [ "$MODE" = "__burst" ]; then
  COUNT="$(intval "${2:-}" 8)"
  [ "$COUNT" -lt 1 ] && COUNT=1
  GAP_SPAN=$(( GAP_MAX - GAP_MIN + 1 ))

  i=0
  while [ "$i" -lt "$COUNT" ]; do
    SOUND="${SOUNDS[$(rand_below "$N")]}"
    # Background each clack so keystrokes can overlap slightly, like a real keyboard.
    [ -f "$SOUND" ] && "${PLAY_CMD[@]}" "$SOUND" </dev/null >/dev/null 2>&1 &
    i=$(( i + 1 ))
    if [ "$i" -lt "$COUNT" ]; then
      GAP_MS=$(( GAP_MIN + $(rand_below "$GAP_SPAN") ))
      sleep "$(printf '0.%03d' "$GAP_MS")"
    fi
  done
  wait
  exit 0
fi

# Launcher mode. Read stdin fully (also drains the event so the writer can't block).
EVENT="$(cat 2>/dev/null)"

if [ -n "$FIXED_COUNT" ] && [ -z "${FIXED_COUNT//[0-9]/}" ]; then
  COUNT="$FIXED_COUNT"
else
  # Sum the lengths of inserted-text fields (content / new_string / new_source).
  # awk walks the JSON purely as data — no shell eval — and stops early once the
  # count would already hit MAX, so a huge file write isn't scanned to the end.
  CAP=$(( (MAX + 1) * CPC ))
  CHARS="$(printf '%s' "$EVENT" | awk -v cap="$CAP" '
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

# Detach so the burst outlives this script. setsid gives its own session
# (survives a group SIGTERM, not just SIGHUP); nohup is the fallback.
if command -v setsid >/dev/null 2>&1; then
  setsid "$SELF" __burst "$COUNT" </dev/null >/dev/null 2>&1 &
else
  nohup "$SELF" __burst "$COUNT" </dev/null >/dev/null 2>&1 &
fi
disown 2>/dev/null

exit 0
