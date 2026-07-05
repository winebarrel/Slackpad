#!/usr/bin/env bash
#
# record-demo.sh — Record a scripted Slackpad demo as demo.gif + demo.mp4.
#
# Opens the installed app (/Applications/Slackpad.app by default) against a
# throwaway notes folder and cascades it in front of the Slack app (Slackpad
# top-left, Slack behind bottom-right). It then drives a scripted demo (new
# note -> rename -> type body -> post a few messages to Slack) via System
# Events while screen-recording the union of both windows with ffmpeg, so the
# posts show up live in Slack. Finally it exports an optimized GIF and a
# web-ready mp4. Set SHOW_SLACK=0 to record only the Slackpad window.
# If APP_PATH does not exist it falls back to a Debug build via xcodebuild.
#
# Requirements:
#   - ffmpeg  (brew install ffmpeg); Xcode only for the build fallback
#   - The terminal running this script must have BOTH "Screen Recording" and
#     "Accessibility" permission in System Settings > Privacy & Security.
#   - For the Slack cascade: the Slack app open on the channel the webhook
#     posts to (SHOW_SLACK=1, the default).
#
# WARNING:
#   - Every *.txt in NOTES_DIR is moved to the Trash before recording so the
#     sidebar starts empty. Point NOTES_DIR at a disposable demo folder.
#   - The demo presses Return in the Slack field several times, posting real
#     messages to the Slack webhook configured in the app.
#
# Usage:
#   scripts/record-demo.sh                 # record, write ./demo.{gif,mp4}
#   OUT_DIR=docs/images scripts/record-demo.sh
#   APP_PATH=/path/to/Slackpad.app scripts/record-demo.sh   # use a specific build
#
set -euo pipefail

### Config (override via environment) ##################################
APP_NAME="${APP_NAME:-Slackpad}"
BUNDLE_ID="${BUNDLE_ID:-jp.winebarrel.Slackpad}"
REPO="${SLACKPAD_REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
NOTES_DIR="${SLACKPAD_DEMO_NOTES:-$HOME/Documents/Slackpad}"   # emptied to Trash!
OUT_DIR="${OUT_DIR:-$PWD}"
# Slackpad window (front, top-left of the cascade).
PAD_X="${PAD_X:-500}"; PAD_Y="${PAD_Y:-200}"
PAD_W="${PAD_W:-820}"; PAD_H="${PAD_H:-500}"
# Slack window (behind, bottom-right). Set SHOW_SLACK=0 to record Slackpad only.
SHOW_SLACK="${SHOW_SLACK:-1}"
SLACK_APP="${SLACK_APP:-Slack}"
SLK_X="${SLK_X:-610}"; SLK_Y="${SLK_Y:-360}"
SLK_W="${SLK_W:-820}"; SLK_H="${SLK_H:-610}"
MARGIN="${MARGIN:-80}"                       # desktop padding around the capture
SLACK_CLEAR_LINES="${SLACK_CLEAR_LINES:-12}" # spacer posts to push old messages up
SLACK_CHANNEL="${SLACK_CHANNEL:-general}"    # channel to (re)open so it shows newest
GIF_WIDTH="${GIF_WIDTH:-720}"
GIF_FPS="${GIF_FPS:-15}"
APP_PATH="${APP_PATH:-/Applications/$APP_NAME.app}"
########################################################################

log() { printf '==> %s\n' "$*"; }
tmp() { mktemp -d "${TMPDIR:-/tmp}/slackpad-demo.XXXXXX"; }

# Move an app's front window to x,y at size w,h and raise it to the front.
position_window() { # appName x y w h
  osascript - "$1" "$2" "$3" "$4" "$5" >/dev/null <<'APPLESCRIPT'
on run argv
	set appName to item 1 of argv
	set wx to (item 2 of argv) as integer
	set wy to (item 3 of argv) as integer
	set ww to (item 4 of argv) as integer
	set wh to (item 5 of argv) as integer
	tell application appName to activate
	delay 0.4
	tell application "System Events" to tell process appName
		set frontmost to true
		set position of window 1 to {wx, wy}
		set size of window 1 to {ww, wh}
	end tell
end run
APPLESCRIPT
}

# Poll until an app has at least one window, up to a timeout (seconds).
wait_for_window() { # appName timeout
  local app="$1" deadline=$(( SECONDS + ${2:-15} )) n
  while (( SECONDS < deadline )); do
    n=$(osascript -e "tell application \"System Events\" to count (windows of process \"$app\")" 2>/dev/null) || n=0
    [[ "$n" =~ ^[0-9]+$ ]] && (( n > 0 )) && return 0
    sleep 0.5
  done
  return 1
}

command -v ffmpeg >/dev/null || { echo "ffmpeg not found (brew install ffmpeg)" >&2; exit 1; }

# 1. Use the installed app at APP_PATH; fall back to a Debug build if missing.
if [[ ! -d "$APP_PATH" ]]; then
  DD="$(tmp)/DerivedData"
  log "$APP_PATH not found — building $APP_NAME (Debug)..."
  xcodebuild -project "$REPO/$APP_NAME.xcodeproj" -scheme "$APP_NAME" \
    -configuration Debug -derivedDataPath "$DD" build >/dev/null
  APP_PATH="$DD/Build/Products/Debug/$APP_NAME.app"
fi
[[ -d "$APP_PATH" ]] || { echo "App bundle not found: $APP_PATH" >&2; exit 1; }
log "Using $APP_PATH"

# 2. Quit any running instance so there is exactly one window to drive.
osascript -e "tell application \"$APP_NAME\" to quit" 2>/dev/null || true
pkill -x "$APP_NAME" 2>/dev/null || true; sleep 1
pkill -9 -x "$APP_NAME" 2>/dev/null || true; sleep 1

# 3. Clean slate: empty the demo notes folder (to Trash) and drop the stale
#    "last open note" pointer + leftover SwiftUI preview temp folders so the
#    app launches on the empty "Select a Note" placeholder.
if [[ -d "$NOTES_DIR" ]]; then
  log "Emptying $NOTES_DIR (files moved to Trash)..."
  while IFS= read -r -d '' f; do
    osascript -e "tell application \"Finder\" to move (POSIX file \"$f\" as alias) to trash" >/dev/null 2>&1 || true
  done < <(find "$NOTES_DIR" -maxdepth 1 -name '*.txt' -print0)
fi
defaults delete "$BUNDLE_ID" lastOpenNote 2>/dev/null || true
rm -rf "$HOME/Library/Containers/$BUNDLE_ID/Data/tmp/SlackpadPreview-"* 2>/dev/null || true

# 4. Launch and lay out the cascade: Slack behind (bottom-right), Slackpad in
#    front (top-left). Both apps are started here (works from a cold state) and
#    we wait for their windows before positioning. Placing Slack first and
#    Slackpad last leaves Slackpad frontmost, so keystrokes go to it while Slack
#    stays visible behind.
log "Launching $APP_NAME..."
open "$APP_PATH"
if [[ "$SHOW_SLACK" == "1" ]]; then
  open -g -a "$SLACK_APP" 2>/dev/null || { log "$SLACK_APP not installed — recording $APP_NAME only."; SHOW_SLACK=0; }
fi

wait_for_window "$APP_NAME" 20 || { echo "$APP_NAME window never appeared" >&2; exit 1; }
if [[ "$SHOW_SLACK" == "1" ]]; then
  # Slack can be slow to restore its workspace on a cold start.
  if wait_for_window "$SLACK_APP" 30 && position_window "$SLACK_APP" "$SLK_X" "$SLK_Y" "$SLK_W" "$SLK_H" 2>/dev/null; then
    log "Placed $SLACK_APP behind $APP_NAME."
  else
    log "$SLACK_APP window not available — recording $APP_NAME only."
    SHOW_SLACK=0
  fi
fi
position_window "$APP_NAME" "$PAD_X" "$PAD_Y" "$PAD_W" "$PAD_H"

# 5. Find the screen-capture device index and the point->pixel scale so the
#    crop lines up on both Retina and 1x displays.
# (ffmpeg -list_devices always exits non-zero, so shield it from `set -e`.)
SCREEN_IDX=$(ffmpeg -hide_banner -f avfoundation -list_devices true -i "" 2>&1 \
  | sed -n 's/.*\[\([0-9]*\)\] Capture screen 0.*/\1/p' | head -1) || true
[[ -n "$SCREEN_IDX" ]] || { echo "No 'Capture screen 0' device from ffmpeg" >&2; exit 1; }
# Logical size in points (main display); the "UI Looks like" line reports it.
read -r LOGICAL_W LOGICAL_H < <(system_profiler SPDisplaysDataType 2>/dev/null \
  | sed -n 's/.*UI Looks like: \([0-9][0-9]*\) x \([0-9][0-9]*\).*/\1 \2/p' | head -1)
[[ -n "$LOGICAL_W" && -n "$LOGICAL_H" ]] || { echo "Could not read logical screen size" >&2; exit 1; }
PROBE="$(tmp)/probe.png"
ffmpeg -hide_banner -loglevel error -y -f avfoundation -framerate 30 -i "$SCREEN_IDX" \
  -frames:v 1 "$PROBE"
CAP_W=$(ffprobe -v error -select_streams v:0 -show_entries stream=width -of csv=p=0 "$PROBE")

# Capture rectangle in points: the union of both windows, or just Slackpad.
if [[ "$SHOW_SLACK" == "1" ]]; then
  CX=$(( PAD_X < SLK_X ? PAD_X : SLK_X ))
  CY=$(( PAD_Y < SLK_Y ? PAD_Y : SLK_Y ))
  RX=$(( PAD_X + PAD_W > SLK_X + SLK_W ? PAD_X + PAD_W : SLK_X + SLK_W ))
  BY=$(( PAD_Y + PAD_H > SLK_Y + SLK_H ? PAD_Y + PAD_H : SLK_Y + SLK_H ))
  CW=$(( RX - CX )); CH=$(( BY - CY ))
else
  CX=$PAD_X; CY=$PAD_Y; CW=$PAD_W; CH=$PAD_H
fi

# Add outer margin, clamped to the screen so ffmpeg's crop stays in-frame.
CX=$(( CX - MARGIN )); CY=$(( CY - MARGIN ))
CW=$(( CW + 2 * MARGIN )); CH=$(( CH + 2 * MARGIN ))
(( CX < 0 )) && { CW=$(( CW + CX )); CX=0; }
(( CY < 0 )) && { CH=$(( CH + CY )); CY=0; }
(( CX + CW > LOGICAL_W )) && CW=$(( LOGICAL_W - CX ))
(( CY + CH > LOGICAL_H )) && CH=$(( LOGICAL_H - CY ))

read -r cx cy cw ch < <(awk -v s="$CAP_W" -v l="$LOGICAL_W" \
  -v x="$CX" -v y="$CY" -v w="$CW" -v h="$CH" 'BEGIN{
    sc = s / l
    cw = int(w*sc); ch = int(h*sc)
    cw -= cw % 2; ch -= ch % 2   # yuv420p needs even dimensions
    printf "%d %d %d %d\n", int(x*sc), int(y*sc), cw, ch
  }')
CROP="crop=$cw:$ch:$cx:$cy"
log "Screen device $SCREEN_IDX; crop $CROP"

# 6. Write the demo driver (System Events keystrokes).
DEMO="$(tmp)/demo.applescript"
cat > "$DEMO" <<'APPLESCRIPT'
-- Slackpad demo: new note -> rename -> type body -> post to Slack
on typeText(s)
	tell application "System Events"
		repeat with i from 1 to (count of characters of s)
			keystroke (character i of s)
			delay 0.05
		end repeat
	end tell
end typeText

on newline_()
	tell application "System Events" to keystroke return
	delay 0.2
end newline_

-- Type a Slack message and send it (Return posts to Slack and appends a
-- timestamped line to the note); pause so it visibly lands in Slack.
on postMessage(msg)
	my typeText(msg)
	delay 0.3
	tell application "System Events" to keystroke return
	delay 1.4
end postMessage

on run argv
	set appName to item 1 of argv
	tell application appName to activate
	delay 0.8

	-- New note (Cmd+N): the sidebar rename field opens with "Untitled" selected.
	tell application "System Events" to keystroke "n" using command down
	delay 1.0
	my typeText("Sprint planning")
	delay 0.4
	tell application "System Events" to keystroke return
	delay 0.9

	-- Move focus into the editor (Cmd+L: sidebar -> post field -> editor).
	tell application "System Events"
		keystroke "l" using command down
		delay 0.4
		keystroke "l" using command down
	end tell
	delay 0.7

	-- Write the note body.
	my typeText("Sprint Planning Q3")
	my newline_()
	my newline_()
	my typeText("Agenda")
	my newline_()
	my typeText("- Confirm the release date")
	my newline_()
	my typeText("- Assign the follow-ups")
	my newline_()
	my typeText("- Triage open bugs")
	my newline_()
	my newline_()
	my typeText("Decisions")
	my newline_()
	my typeText("- Ship the beta on Friday")
	my newline_()
	my typeText("- Freeze scope after review")
	my newline_()
	my newline_()
	my typeText("Notes")
	delay 0.6

	-- Jump to the Slack field (Cmd+L from editor) and post a few messages.
	tell application "System Events" to keystroke "l" using command down
	delay 0.7
	my postMessage("Sprint planning kicked off")
	my postMessage("Release date confirmed: Friday")
	my postMessage("Beta build is up for testing")

	-- Hold so the last appended, timestamped line stays on screen.
	delay 2.2
end run
APPLESCRIPT

# 6b. Push old Slack messages out of view by posting a few "~" spacer lines
#     through the webhook before recording (keeps the demo note clean).
if [[ "$SHOW_SLACK" == "1" && "$SLACK_CLEAR_LINES" -gt 0 ]]; then
  WEBHOOK=$(defaults read "$BUNDLE_ID" webhookURL 2>/dev/null || true)
  if [[ "$WEBHOOK" == https://hooks.slack.com/* ]]; then
    log "Clearing Slack view ($SLACK_CLEAR_LINES spacer lines)..."
    for _ in $(seq 1 "$SLACK_CLEAR_LINES"); do
      curl -s -o /dev/null -X POST -H 'Content-type: application/json' \
        --data '{"text":"~"}' "$WEBHOOK" || true
      sleep 0.25
    done
    sleep 1.0   # let Slack render and scroll to the newest line
  fi
fi

# 6c. Force Slack to the newest message. A cold-started client may not follow
#     incoming webhook posts, so reopen the channel via the quick switcher
#     (Cmd+K) — that always lands at the bottom of the channel.
if [[ "$SHOW_SLACK" == "1" ]]; then
  osascript - "$SLACK_APP" "$SLACK_CHANNEL" >/dev/null <<'APPLESCRIPT'
on run argv
	set slackApp to item 1 of argv
	set chan to item 2 of argv
	tell application slackApp to activate
	delay 0.6
	tell application "System Events"
		keystroke "k" using command down
		delay 0.7
		keystroke chan
		delay 0.7
		key code 36 -- Return: navigate to the channel (scrolls to newest)
		delay 1.0
	end tell
end run
APPLESCRIPT
fi

# 7. Record while the demo runs; SIGINT ends ffmpeg cleanly (writes moov atom).
RAW="$(tmp)/demo_raw.mp4"
log "Recording..."
osascript -e "tell application \"$APP_NAME\" to activate" >/dev/null; sleep 0.6
ffmpeg -hide_banner -loglevel error -y -f avfoundation -capture_cursor 1 -framerate 30 \
  -i "$SCREEN_IDX" -vf "$CROP" -c:v libx264 -pix_fmt yuv420p -r 30 "$RAW" </dev/null &
FF=$!
sleep 1.8
osascript "$DEMO" "$APP_NAME"
sleep 0.5
kill -INT "$FF" 2>/dev/null || true
wait "$FF" 2>/dev/null || true

# 8. Export a web-ready mp4 and a palette-optimized GIF.
mkdir -p "$OUT_DIR"
log "Writing $OUT_DIR/demo.mp4 and $OUT_DIR/demo.gif..."
ffmpeg -hide_banner -loglevel error -y -i "$RAW" -c:v libx264 -pix_fmt yuv420p \
  -movflags +faststart -crf 20 "$OUT_DIR/demo.mp4"
PAL="$(tmp)/palette.png"
ffmpeg -hide_banner -loglevel error -y -i "$RAW" \
  -vf "fps=$GIF_FPS,scale=$GIF_WIDTH:-1:flags=lanczos,palettegen=stats_mode=diff" "$PAL"
ffmpeg -hide_banner -loglevel error -y -i "$RAW" -i "$PAL" \
  -lavfi "fps=$GIF_FPS,scale=$GIF_WIDTH:-1:flags=lanczos[x];[x][1:v]paletteuse=dither=bayer:bayer_scale=3" \
  "$OUT_DIR/demo.gif"

log "Done."
