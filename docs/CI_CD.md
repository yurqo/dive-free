# CI/CD

## What CI does

Every push to `main` and every pull request triggers the **CI** workflow
(`.github/workflows/ci.yml`) on a `macos-26` GitHub-hosted runner (Apple Silicon,
Xcode 26.4.x).

| Step | Details |
|---|---|
| Generate workspace | `tuist generate` rebuilds the `.xcworkspace` from `Project.swift` |
| Test — Domain | `xcodebuild test` on the iOS Simulator |
| Test — Persistence | Same |
| Test — Sensors | Same |
| Test — Sync | Same |
| Test — Strava | Same |
| Build — DiveFreeWatch | `xcodebuild build` for the watchOS Simulator |
| Build — DiveFree | `xcodebuild build` for the iOS Simulator (embeds Watch app) |

CI takes roughly **8–12 minutes** on a fresh runner (most of that is simulator boot
and the first `xcodebuild` compilation; subsequent runs are faster via runner-level
DerivedData reuse when available).

### Reading a failure

1. Click **Details** on the failed check from the PR or commit page.
2. Expand the step that failed — `xcbeautify` output shows the exact compiler
   error or failing test assertion.
3. If a **test** step failed, a `test-results` artifact bundle is uploaded
   automatically. Download it from the workflow summary, then double-click the
   `.xcresult` to open it in Xcode's Test Report navigator for the full failure
   details.

### Updating the Tuist version

1. Run `brew upgrade tuist` locally and note the new version.
2. Edit `mise.toml` — update the `tuist` version string.
3. Run `tuist generate --no-open` locally to confirm nothing breaks.
4. Commit and push.

---

## Enabling TestFlight delivery (CD)

The **TestFlight** workflow (`.github/workflows/testflight.yml`) is currently
**manual-only** (`workflow_dispatch`) and exits early if any required secret is
missing. Nothing will accidentally deploy.

### Prerequisites

You need all four of these before wiring CD:

| Prerequisite | How to get it |
|---|---|
| **Apple Developer Program** membership | [developer.apple.com/programs](https://developer.apple.com/programs/) — USD $99/year |
| **Bundle ID registered** | Register `net.perekupko.divefree` in [Identifiers](https://developer.apple.com/account/resources/identifiers/list) |
| **App record in App Store Connect** | Create an app at [appstoreconnect.apple.com](https://appstoreconnect.apple.com) with the bundle ID above |
| **App Store Connect API key** | In App Store Connect → Users & Access → Integrations → App Store Connect API — create a key with **App Manager** role; download the `.p8` file (only downloadable once) |

### Secrets to add to the repo

Go to **GitHub → Settings → Secrets and variables → Actions** and add:

| Secret name | Value |
|---|---|
| `APP_STORE_CONNECT_KEY_ID` | The Key ID shown in App Store Connect (e.g. `ABC1234DEF`) |
| `APP_STORE_CONNECT_ISSUER_ID` | The Issuer ID shown on the same page (UUID format) |
| `APP_STORE_CONNECT_API_KEY` | The `.p8` file contents, **base64-encoded**: `base64 -i AuthKey_XXX.p8 | pbcopy` |
| `TEAM_ID` | Your Apple Team ID (10-char string shown in developer.apple.com under Membership) |

### Enabling automatic delivery on tags

Once the secrets are set and you've done at least one manual dispatch to confirm
the archive and upload steps work:

1. Open `.github/workflows/testflight.yml`.
2. Replace the trigger block:
   ```yaml
   on:
     workflow_dispatch:
   ```
   with:
   ```yaml
   on:
     workflow_dispatch:      # keep for manual runs
     push:
       tags: ['v*']         # auto-deliver on version tags like v1.0.0
   ```
3. Uncomment the four TODO steps in the workflow (write key, archive, export, upload).
4. Create an `ExportOptions.plist` at the repo root:
   ```xml
   <?xml version="1.0" encoding="UTF-8"?>
   <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
     "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
   <plist version="1.0">
   <dict>
     <key>method</key>
     <string>app-store</string>
     <key>teamID</key>
     <string>YOUR_TEAM_ID</string>
     <key>uploadBitcode</key>
     <false/>
   </dict>
   </plist>
   ```
5. Push the changes and create a tag (`git tag v0.1.0 && git push --tags`) to
   trigger the first automated delivery.
