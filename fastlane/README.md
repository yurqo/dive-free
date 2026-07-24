fastlane documentation
----

# Installation

Make sure you have the latest version of the Xcode command line tools installed:

```sh
xcode-select --install
```

For _fastlane_ installation instructions, see [Installing _fastlane_](https://docs.fastlane.tools/#installing-fastlane)

# Available Actions

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

### ios validate

```sh
[bundle exec] fastlane ios validate
```

Validate metadata with the precheck action only (no upload).

----

This README.md is auto-generated and will be re-generated every time [_fastlane_](https://fastlane.tools) is run.

More information about _fastlane_ can be found on [fastlane.tools](https://fastlane.tools).

The documentation of _fastlane_ can be found on [docs.fastlane.tools](https://docs.fastlane.tools).
