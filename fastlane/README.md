# Fastlane — App Store Connect delivery

This directory drives **`deliver`** (`upload_to_app_store`) to push DiveFree's
localized App Store metadata and screenshots to App Store Connect in one command.

It is **delivery tooling only** — it does not build, sign, or upload a binary
(that's the TestFlight workflow). Everything it uploads goes to a **DRAFT**; it
never submits for review.

## What it does

- Uploads localized metadata from [`metadata/`](metadata/) — the committed
  **source of truth** for the App Store listing (name, subtitle, description,
  keywords, promotional text, per-locale What's New, support/privacy URLs,
  categories, copyright).
- Stages screenshots from the repo's top-level `screenshots/` folder into
  `fastlane/screenshots/` (gitignored, recreated each run) and uploads them.
  Regenerate the source screenshots with `Scripts/screenshots.sh`.

## Prerequisites

1. [`mise`](https://mise.jdx.dev) — pins the Ruby version (see the repo's
   `mise.toml`). The machine's system Ruby (2.6) can't `bundle install` without
   sudo, so use the mise-pinned Ruby instead.
2. The App Store Connect API key (same one CI uses — see
   `.github/workflows/testflight.yml`).

## One-time setup

Install the pinned Ruby and the gems into a project-local `vendor/bundle`:

```sh
mise install                              # installs the pinned Ruby (and tuist)
bundle config set --local path vendor/bundle
bundle install
```

`vendor/bundle/` and `.bundle/` are gitignored — the gems stay local to the
checkout and never need sudo.

## Run

Export the three ASC env vars, then run a lane. The API key `.p8` must be passed
**base64-encoded** (matching the `APP_STORE_CONNECT_API_KEY` GitHub secret):

```sh
export APP_STORE_CONNECT_KEY_ID="<key id>"
export APP_STORE_CONNECT_ISSUER_ID="<issuer id>"
export APP_STORE_CONNECT_API_KEY="$(base64 -i AuthKey_XXXXXXXX.p8)"

bundle exec fastlane metadata
```

`metadata` uploads a **DRAFT** — it never submits for review. Screenshots come
from the top-level `screenshots/` folder (regenerate with
`Scripts/screenshots.sh`).

Never commit or paste these values — they live only in the environment.

## Operational gotchas

Read these before running `metadata` — `deliver` will fail or clobber the
listing if the ASC state isn't right.

### A draft App Store version must exist in ASC first

`deliver` targets the **current editable** App Store version. If the latest
version is already released and there's no new "Prepare for Submission" version,
the upload fails with **"Could not find a version to update."**

Create the new version page (e.g. **1.3.0**) in App Store Connect first, under
the app's **App Store** tab → **+ Version or Platform**. That editable version
also exists automatically once a new TestFlight build is attached to a fresh
version. Only then will `metadata` have somewhere to write.

### `overwrite_screenshots: true` replaces the listing's screenshots

Every uploaded locale has its screenshots **replaced** with what we staged.
DiveFree targets only **6.9" iPhone** and **13" iPad** — those are the only
sizes we generate and upload. If the ASC listing for a locale has screenshots
for *other* device sizes, uploading would clear them.

Regenerate the source screenshots with `Scripts/screenshots.sh` before every
upload so the staged set is current.

### Recommended safe sequence

```sh
bundle exec fastlane precheck      # validate metadata (no upload)
# review the precheck output, fix any findings
bundle exec fastlane metadata      # uploads a DRAFT — never submits
# verify the draft in App Store Connect
# submit for review manually from ASC
```

## Lanes

| Lane | What it does |
|---|---|
| `metadata` | Stage screenshots + upload **metadata and screenshots** as a draft. **Does not submit.** Run `precheck` first to validate. |
| `screenshots_only` | Stage + upload **screenshots only** (skips metadata text). Does not submit. |
| `precheck` | Validate metadata via `precheck` only — **no upload**. |

All lanes use `force: true` (skips the HTML preview prompt) and
`submit_for_review: false`. Nothing is ever submitted for review from here.

## Locale mapping

The `screenshots/` folder uses short locale codes; ASC uses full ones. The
`metadata/` tree and the screenshot staging both use these ASC codes:

| screenshots/ | ASC (metadata/) |
|---|---|
| `en` | `en-US` |
| `es` | `es-ES` |
| `fr` | `fr-FR` |
| `it` | `it` |
| `de` | `de-DE` |
| `pt-BR` | `pt-BR` |
| `ja` | `ja` |
| `uk` | `uk` |
