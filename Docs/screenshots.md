# App Store screenshots

LibreBase's App Store screenshots are generated deterministically — no manual
posing, no live scale. The pipeline launches the app in a fixed state per scene,
captures on the simulator, and frames the result in an Apple device bezel.

## How it works

- **`ScreenshotSupport.swift`** reads `-SCREENSHOT_MODE -SCREENSHOT_SCENE <scene>`
  at launch and seeds `UserDefaults` (and a demo weigh-in via
  `ScaleClient.loadDemoReading`) so each scene renders without onboarding,
  permission prompts, or a real scale. Scenes are reached directly from launch
  args — no taps — so the run is stable across devices.
- **`.asc/screenshots.json`** is the scene manifest (name, scene arg, wait).
- **`.asc/shots.settings.json`** is the pipeline config (simulator, frame device,
  paths, upload toggle).
- **`Scripts/generate-screenshots.sh`** orchestrates build → capture → frame.

Scenes: `welcome`, `how_it_works`, `reading` (demo 72.6 kg weigh-in + BMI),
`privacy`.

## Generate

```bash
Scripts/generate-screenshots.sh            # build + capture + frame
Scripts/generate-screenshots.sh capture    # capture + frame (skip build)
Scripts/generate-screenshots.sh frame      # frame only (reuse screenshots/raw)
```

Raw PNGs land in `screenshots/raw/`, framed 6.9" (1320×2868) PNGs in
`screenshots/framed/`. Both directories are git-ignored — regenerate as needed.

Framing uses `asc screenshots frame` (Koubou, device `iphone-17-pro-max`).
Install Koubou once: `pip install koubou==0.18.1`.

## Upload

Upload is intentionally manual (`upload_enabled: false`), done only after a visual
review. Resolve the en-US version-localization id, then upload:

```bash
asc versions list --app 6775892745 --output table
asc localizations list --version "<VERSION_ID>" --locale en-US --output json
asc screenshots upload \
  --version-localization "<LOC_ID>" \
  --path "screenshots/framed" \
  --device-type IPHONE_69 \
  --output table
```
