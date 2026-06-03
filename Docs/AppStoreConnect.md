# App Store Connect

LibreBase is a **free** app (no in-app purchases, no subscriptions). This is the
release reference for the `asc` CLI.

- **App ID:** `6775892745`
- **Bundle ID:** `com.michelstorms.LibreBase`
- **Category:** Health & Fitness (`public.app-category.healthcare-fitness`, set in
  build settings)
- **Privacy policy:** <https://michelstorms.com/librebase/privacy/> — source of
  truth is [`PRIVACY.md`](../PRIVACY.md); publish it at that URL before submitting.

## Canonical metadata

App Store text lives in `./metadata` (pulled with `asc metadata pull`), matching
the layout the other apps use:

```
metadata/
├── app-info/en-US.json          # name, subtitle, privacyPolicyUrl
└── version/1.0.0/en-US.json     # description, keywords, promotionalText, urls
```

The version folder name and `--version` must match the **ASC** version string,
which is `1.0.0` (and matches the build's `MARKETING_VERSION`). Edit locally,
validate, then push:

```bash
asc metadata validate --dir ./metadata
asc metadata push --app 6775892745 --version 1.0.0 --platform IOS --dir ./metadata
```

## Screenshots

See [`screenshots.md`](screenshots.md). Generate with
`Scripts/generate-screenshots.sh`, then upload the framed set to the en-US
version-localization (`--device-type IPHONE_69`).

## Configured via the App Store Connect UI

A few items aren't covered by the metadata APIs and are set in the ASC web UI:

- **App Privacy ("nutrition label"):** declare **Data Not Collected** — LibreBase
  collects nothing (see `PRIVACY.md`).
- **Age rating:** answer the questionnaire (no objectionable content → 4+).
- **Categories** are mirrored from the build setting above.

## Release flow

```bash
# Latest build / next build number
asc builds list --app 6775892745 --sort -uploadedDate --limit 5
# After uploading a build, attach it to the version and submit (when ready):
asc submission ...    # see `asc submission --help`
```

Builds are uploaded from Xcode (Organizer) or via `asc`; version/build numbers are
set in Xcode by Michel.
