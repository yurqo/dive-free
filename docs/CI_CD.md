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

### Building a signed app locally (archive)

CI and tests build unsigned, so `DEVELOPMENT_TEAM` is empty by default. To
produce a signed build/archive locally (e.g. to register App IDs or archive for
the App Store), pass your Team ID via `TUIST_DEVELOPMENT_TEAM` when generating —
Tuist only forwards `TUIST_`-prefixed variables into `Project.swift`:

```sh
TUIST_DEVELOPMENT_TEAM=YOURTEAMID tuist generate
```

The team is baked into every target; then **Product → Archive** in Xcode with
automatic signing. (CI's TestFlight job passes the team to `xcodebuild` directly
via the `APPLE_TEAM_ID` secret, so it doesn't need this.)

### Updating the Tuist version

1. Run `brew upgrade tuist` locally and note the new version.
2. Edit `mise.toml` — update the `tuist` version string.
3. Run `tuist generate --no-open` locally to confirm nothing breaks.
4. Commit and push.

---

## Enabling TestFlight delivery (CD)

The **Deliver to TestFlight** workflow (`.github/workflows/testflight.yml`) is
**wired up**: it's manually triggered (`workflow_dispatch`) with a **version
bump** input, then archives, exports, and uploads to App Store Connect. It is
**safe by default** — a Preflight step exits early with clear guidance if any
required secret is missing.

To go live you only need to complete the **prerequisites** and add the
**secrets** below; the workflow code and `ExportOptions.plist` are already in the
repo.

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
| `BUILD_CERTIFICATE_BASE64` | Your signing cert(s) exported as a `.p12`, base64-encoded: `base64 -i Certificates.p12 | pbcopy` |
| `P12_PASSWORD` | The password you set when exporting the `.p12` |

#### Why a stored certificate

CI imports this one `.p12` into a temporary keychain instead of letting Xcode
mint a fresh **Apple Development** certificate on every run — which eventually
trips Apple's per-account certificate limit ("maximum number of certificates").
Provisioning profiles are still created/managed automatically via the API key
(profiles aren't capped). To create the `.p12`:

1. In **Xcode → Settings → Accounts → Manage Certificates**, ensure you have an
   **Apple Distribution** (and **Apple Development**) certificate — the **+** button
   creates one whose private key lands in your login keychain. Revoke stale
   CI-generated certs in the developer portal to get back under the limit.
2. In **Keychain Access**, select those certificate(s) **with their private keys**,
   right-click → **Export 2 items…** → save as `Certificates.p12` with a password.
3. `base64 -i Certificates.p12 | pbcopy` → paste into `BUILD_CERTIFICATE_BASE64`;
   put the password in `P12_PASSWORD`.

### Versioning model

The **patch version auto-increments** — a plain dispatch ships the next patch:

- The workflow reads the latest `vX.Y.Z` release tag, **bumps the patch**, builds,
  and **pushes the new tag on success**. With no tags yet, it ships the
  `MARKETING_VERSION` in `Project.swift`.
- To **jump versions** (e.g. a new minor), set `MARKETING_VERSION` in
  `Project.swift` *higher* than the latest tag — CI uses it verbatim for that one
  release, then resumes auto-incrementing from there.
- The **build number** (`CFBundleVersion`) tracks the patch, so version and build
  stay aligned (`1.0.13` → build `13`).

`ExportOptions.plist` deliberately omits `teamID`: the signing team is resolved
from the App Store Connect API key (`-allowProvisioningUpdates`), and the archive
is signed with the `APPLE_TEAM_ID` secret via `DEVELOPMENT_TEAM`.

### Triggering delivery

Once the prerequisites and secrets above are in place, run it manually — from the
CLI or the Actions UI:

```sh
make testflight   # or: gh workflow run testflight.yml
```

The build appears in App Store Connect → **TestFlight** within ~30 minutes
("Processing" first). For an App Store **release**, submit the build for review in
App Store Connect when ready.

Until the secrets exist, every run stops at the Preflight step with a clear
message — nothing deploys by accident.
