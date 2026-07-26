fastlane documentation
----

# Installation

Make sure you have the latest version of the Xcode command line tools installed:

```sh
xcode-select --install
```

For _fastlane_ installation instructions, see [Installing _fastlane_](https://docs.fastlane.tools/#installing-fastlane)

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
