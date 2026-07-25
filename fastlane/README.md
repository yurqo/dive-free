fastlane documentation
----

# Installation

Make sure you have the latest version of the Xcode command line tools installed:

```sh
xcode-select --install
```

For _fastlane_ installation instructions, see [Installing _fastlane_](https://docs.fastlane.tools/#installing-fastlane)

# Screenshots

The images the lanes below upload are produced by `Scripts/screenshots.sh`, which
writes `screenshots/<locale>/<device>/NN-slug.png` for all 8 locales and is the
single entry point for **two** pipelines:

```sh
Scripts/screenshots.sh            # both
Scripts/screenshots.sh --ios      # iPhone + iPad only
Scripts/screenshots.sh --watch    # Apple Watch only
```

- **iOS** (`iPhone 17 Pro Max`, `iPad Pro 13-inch (M5)`) — an XCUITest
  (`ScreenshotTests`) walks the app and attaches the captures; the script exports
  them from the xcresult, so each device dir also holds a `manifest.json` mapping
  the exported UUID filenames back to `NN-slug` names.
- **Apple Watch** (`Apple Watch Ultra 3 (49mm)`, captured at 422×514 = App Store
  Connect's `APP_WATCH_ULTRA`) — there is no XCTest on watchOS, so there is no UI
  automation to drive: the app is installed with `simctl` and launched once per
  screen with `--screenshot-demo --screenshot-screen <NN-slug>` (see
  `WatchScreenshotMode`), then photographed with `simctl io … screenshot`. These
  files are written under their final names and have **no** `manifest.json` —
  `readable_name_for` falls through to the filename, which is already correct.

Both pipelines verify that the requested language actually applied by asking the
app for its *resolved* localization and failing the run on a mismatch, and both
are covered by the cross-locale byte-identical check. Nothing reaches the lanes
below unless `Scripts/screenshots.sh` exits 0.

`stage_screenshots` flattens whatever is on disk into
`fastlane/screenshots/<asc-locale>/<device>-<NN-slug>.png` and `deliver` picks the
App Store display type from each image's dimensions, so adding a device is a
matter of capturing it — no lane changes.

# Available Actions

Recommended order when refreshing the App Store listing:

```sh
[bundle exec] fastlane ios validate            # 1. check the metadata text
[bundle exec] fastlane ios screenshots_purge   # 2. clear stale/duplicate screenshots
[bundle exec] fastlane ios metadata            # 3. upload metadata + screenshots
```

Step 2 matters because `deliver`'s `overwrite_screenshots` has been observed to
leave duplicates behind (uk once ended up with every screenshot twice). Purging
first makes the upload deterministic: what is in `screenshots/` is exactly what
App Store Connect ends up with.

What `screenshots_purge` will and will not touch:

- **Version**: only one that is *not with App Review* — `PREPARE_FOR_SUBMISSION`,
  `DEVELOPER_REJECTED`, `REJECTED`, `METADATA_REJECTED` or `INVALID_BINARY` (a
  build that failed processing leaves the version fully editable). It aborts on
  anything else — notably `WAITING_FOR_REVIEW`, which the underlying spaceship
  "editable version" lookup does match — and can never reach the live version.
- **Locales**: only the ones `metadata` uploads (the `LOCALE_MAP` locales). Any
  other localization present on the version is reported as skipped and left
  alone — there are no local screenshots to restore it with.
- **Verification**: deletes are re-checked against App Store Connect and retried
  up to 5 times, spaced 5/10/15/20s apart to let deletes propagate, because the
  API returns success for deletes it did not perform. Transient API errors are
  retried too; the lane fails rather than claiming a purge it could not confirm.
  A full run against an unhealthy API therefore takes up to ~1 minute.

## iOS

### ios metadata

```sh
[bundle exec] fastlane ios metadata
```

Upload localized metadata + screenshots to App Store Connect as a DRAFT (no binary, no submit). Run `fastlane ios validate` first to validate.

### ios screenshots_only

```sh
[bundle exec] fastlane ios screenshots_only
```

Stage + upload screenshots only (no metadata text changes).

### ios screenshots_purge

```sh
[bundle exec] fastlane ios screenshots_purge
```

Delete the screenshots of the LOCALE_MAP locales from a not-yet-submitted App Store version. Run before `metadata` when ASC has accumulated duplicates.

### ios validate

```sh
[bundle exec] fastlane ios validate
```

Validate metadata with the precheck action only (no upload).

----

This README.md is auto-generated and will be re-generated every time [_fastlane_](https://fastlane.tools) is run.

More information about _fastlane_ can be found on [fastlane.tools](https://fastlane.tools).

The documentation of _fastlane_ can be found on [docs.fastlane.tools](https://docs.fastlane.tools).
