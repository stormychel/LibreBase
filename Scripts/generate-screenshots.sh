#!/usr/bin/env bash
#
#  generate-screenshots.sh
#  LibreBase
#
#  Deterministic App Store screenshot pipeline, modelled on the TrackHound flow.
#  Each scene relaunches the app with `-SCREENSHOT_MODE -SCREENSHOT_SCENE <scene>`
#  (see ScreenshotSupport.swift), waits for it to render, and captures — no taps,
#  so it's stable across devices. Raw shots are framed with `asc screenshots frame`
#  (Koubou). Upload stays manual (see Docs/screenshots.md).
#
#  Usage:
#    Scripts/generate-screenshots.sh            # build + capture + frame
#    Scripts/generate-screenshots.sh capture    # capture + frame (skip build)
#    Scripts/generate-screenshots.sh frame      # frame only (reuse raw/)
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

SETTINGS=".asc/shots.settings.json"
PLAN=".asc/screenshots.json"
DD="/tmp/librebase-shots-dd"

log() { echo "▸ $*"; }

require() { command -v "$1" >/dev/null 2>&1 || { echo "Missing dependency: $1" >&2; exit 1; }; }
require jq
require xcrun

BUNDLE_ID=$(jq -r '.app.bundle_id' "$SETTINGS")
PROJECT=$(jq -r '.app.project' "$SETTINGS")
SCHEME=$(jq -r '.app.scheme' "$SETTINGS")
SIM_NAME=$(jq -r '.app.simulator_name' "$SETTINGS")
OS=$(jq -r '.app.os' "$SETTINGS")
RAW_DIR=$(jq -r '.paths.raw_dir' "$SETTINGS")
FRAMED_DIR=$(jq -r '.paths.framed_dir' "$SETTINGS")
FRAME_DEVICE=$(jq -r '.frame.device' "$SETTINGS")

MODE="${1:-full}"

boot_sim() {
  log "Booting simulator: $SIM_NAME ($OS)"
  # Scope to the requested runtime so we don't grab a same-named device on a
  # different OS (which then fails to install the 26.5-min app).
  local runtime; runtime="iOS-${OS//./-}"
  UDID=$(xcrun simctl list devices available --json \
    | jq -r --arg name "$SIM_NAME" --arg rt "$runtime" \
      '.devices | to_entries[] | select(.key | endswith($rt)) | .value[] | select(.name==$name) | .udid' \
    | head -1)
  [[ -n "$UDID" ]] || { echo "Simulator '$SIM_NAME' on $runtime not found" >&2; exit 1; }
  xcrun simctl boot "$UDID" 2>/dev/null || true
  open -a Simulator || true
  # Clean status bar (9:41, full battery/wifi) for App Store-grade shots.
  xcrun simctl status_bar "$UDID" override \
    --time "09:41" --batteryState charged --batteryLevel 100 \
    --cellularMode active --cellularBars 4 --wifiBars 3 --dataNetwork wifi 2>/dev/null || true
  sleep 3
}

build_app() {
  log "Building $SCHEME for simulator"
  xcrun xcodebuild -project "$PROJECT" -scheme "$SCHEME" \
    -destination "platform=iOS Simulator,name=$SIM_NAME,OS=$OS" \
    -derivedDataPath "$DD" build >/dev/null
}

install_app() {
  APP_PATH="$DD/Build/Products/Debug-iphonesimulator/LibreBase.app"
  [[ -d "$APP_PATH" ]] || { echo "App not built at $APP_PATH — run a full build first" >&2; exit 1; }
  log "Installing $APP_PATH"
  xcrun simctl install "$UDID" "$APP_PATH"
}

capture() {
  rm -rf "$RAW_DIR"; mkdir -p "$RAW_DIR"
  local count; count=$(jq '.scenes | length' "$PLAN")
  for ((i = 0; i < count; i++)); do
    local name scene wait_ms
    name=$(jq -r ".scenes[$i].name" "$PLAN")
    scene=$(jq -r ".scenes[$i].scene" "$PLAN")
    wait_ms=$(jq -r ".scenes[$i].wait_ms" "$PLAN")
    log "Scene $name (scene=$scene)"
    xcrun simctl terminate "$UDID" "$BUNDLE_ID" 2>/dev/null || true
    xcrun simctl launch "$UDID" "$BUNDLE_ID" -SCREENSHOT_MODE -SCREENSHOT_SCENE "$scene" >/dev/null
    sleep "$(awk "BEGIN{print $wait_ms/1000}")"
    xcrun simctl io "$UDID" screenshot "$RAW_DIR/$name.png" >/dev/null
    log "  saved $RAW_DIR/$name.png"
  done
}

frame() {
  require asc
  rm -rf "$FRAMED_DIR"; mkdir -p "$FRAMED_DIR"
  shopt -s nullglob
  local shots=("$RAW_DIR"/*.png)
  [[ ${#shots[@]} -gt 0 ]] || { echo "No raw screenshots in $RAW_DIR" >&2; exit 1; }
  for f in "${shots[@]}"; do
    log "Framing $(basename "$f")"
    asc screenshots frame \
      --input "$f" \
      --output-dir "$FRAMED_DIR" \
      --device "$FRAME_DEVICE" \
      --output json >/dev/null
  done
}

case "$MODE" in
  full)    boot_sim; build_app; install_app; capture; frame ;;
  capture) boot_sim; install_app; capture; frame ;;
  frame)   frame ;;
  *)       echo "Usage: $0 [full|capture|frame]"; exit 1 ;;
esac

cat <<EOF

✅ Done.
   Raw:    $RAW_DIR
   Framed: $FRAMED_DIR

To upload (only once reviewed), resolve the version-localization id, then:
  asc screenshots upload \\
    --version-localization "<LOC_ID>" \\
    --path "$FRAMED_DIR" \\
    --device-type IPHONE_69 \\
    --output table

See Docs/screenshots.md for the full flow.
EOF
