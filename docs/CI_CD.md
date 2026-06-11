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

The **TestFlight** workflow (`.github/workflows/testflight.yml`) is **wired up**:
it runs on every `v*` tag (and on manual `workflow_dispatch`), archives, exports,
and uploads to TestFlight. It is **safe by default** — a Preflight step exits
early with clear guidance if any required secret is missing, so a tag pushed
before the steps below are complete won't attempt (or break) a real upload.

To go live you only need to complete the **prerequisites** and add the
**secrets** below; the workflow code and `ExportOptions.plist` are already in the
repo. Do at least one **manual dispatch** to confirm signing before relying on
tag-triggered delivery.

### Prerequisites

You need all four of these before wiring CD:

| Prerequisite | How to get it |
|---|---|
| **Apple Developer Program** membership | [developer.apple.com/programs](https://developer.apple.com/programs/) — USD $99/year |
| **Bundle ID registered** | Register `org.yurko.divefree` (the `bundlePrefix` in `Project.swift`) in [Identifiers](https://developer.apple.com/account/resources/identifiers/list) — the App Store Connect record must use this exact ID |
| **App record in App Store Connect** | Create an app at [appstoreconnect.apple.com](https://appstoreconnect.apple.com) with the bundle ID above |
| **App Store Connect API key** | In App Store Connect → Users & Access → Integrations → App Store Connect API — create a key with **App Manager** role; download the `.p8` file (only downloadable once) |

### Secrets to add to the repo

Go to **GitHub → Settings → Secrets and variables → Actions** and add:

| Secret name | Value |
|---|---|
| `APP_STORE_CONNECT_KEY_ID` | The Key ID shown in App Store Connect (e.g. `ABC1234DEF`) |
| `APP_STORE_CONNECT_ISSUER_ID` | The Issuer ID shown on the same page (UUID format) |
| `APP_STORE_CONNECT_API_KEY` | The `.p8` file contents, **base64-encoded**: `base64 -i AuthKey_XXX.p8 | pbcopy` |
| `APPLE_TEAM_ID` | Your Apple Team ID (10-char string shown in developer.apple.com under Membership) |

### Triggering delivery

The workflow trigger, the archive/export/upload steps, and the repo-root
`ExportOptions.plist` are **already committed** — there's nothing left to
uncomment. `ExportOptions.plist` deliberately omits `teamID`: the signing team is
resolved from the App Store Connect API key (`-allowProvisioningUpdates`), and the
archive is signed with the `APPLE_TEAM_ID` secret via `DEVELOPMENT_TEAM`.

Once the prerequisites and secrets above are in place:

1. **Validate manually first.** GitHub → Actions → **TestFlight** → *Run
   workflow*. Confirm the archive, export, and upload steps succeed and a build
   shows up in App Store Connect → TestFlight.
2. **Then tag a release:**
   ```sh
   git tag v0.1.0 && git push --tags
   ```
   The `push: tags: ['v*']` trigger runs the same job automatically; a build
   should appear in TestFlight within ~30 minutes.

Until the secrets exist, both paths stop at the Preflight step with a clear
message — nothing deploys by accident.
