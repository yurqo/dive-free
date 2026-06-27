# App Store listing — DiveFree

Copy-paste source for App Store Connect. Character limits noted in parentheses.
Positioning rule: **logbook / travel memory app, not a dive computer** — keep
this consistent everywhere (see `docs/PRD.md`).

## Names & category

- **App name** (≤30): `Dive Free` (or `Dive Free: Freedive Log`, 23 chars)
- **Subtitle** (≤30): `Freedive & snorkel logbook` (26)
- **Primary category:** Travel  _(matches `LSApplicationCategoryType`)_
- **Secondary category:** Sports  _(deliberately not Health & Fitness, to keep
  the app positioned away from "dive computer" scrutiny)_

## Keywords (≤100 chars, comma-separated, no spaces)

```
freediving,snorkeling,freedive,apnea,spearfishing,divelog,logbook,depth,scuba,ocean,diary
```

_(Don't repeat the app name or category words; Apple already indexes those.)_

## Promotional text (≤170, editable any time without review)

```
Log every freedive and snorkel from your Apple Watch — hands-free underwater, with depth charts, dive-spot maps, photos, and Strava export back on your iPhone.
```

## Description (≤4000)

```
Dive Free is the Apple Watch companion for recreational freediving and snorkeling — a beautiful logbook for your time in the water, not a dive computer.

Start a session on your Apple Watch before you get in. Dive Free tracks your depth and dives completely hands-free using the Digital Crown and Action button, so you never have to touch a water-locked screen. Back on the surface, relive every dive on your iPhone with depth charts, maps of your dive spots, and the photos you took that day.

WATCH-FIRST, HANDS-FREE
• Run a session hands-free with the Digital Crown — plus the Action button on Apple Watch Ultra — no taps needed underwater
• Automatic dive detection and surface-interval tracking
• Live depth (to 6 m) and dive duration underwater (Apple Watch Ultra, Series 10, and Series 11)
• Drop event markers during a dive

REMEMBER EVERY DIVE
• Depth-profile chart for each dive
• Dive spots grouped automatically and shown on a map
• Attach photos and videos, including shots from your underwater camera
• Record voice notes and rate your sessions
• Organize your dive media into a "Dive Free" album in Photos

SHARE
• Export the dives you choose to Strava

Dive Free is a logbook and memory platform for recreational freedivers, snorkelers, and travelers. It is NOT a dive computer and has no dive-computer capabilities: it provides no decompression, dive-planning, or safety information, and depth tracking is capped at 6 metres (shallow water). Never use it as a safety device. Always dive within your training, follow your local rules, and never freedive alone.

Apple Watch Ultra is the best experience: it tracks depth and lets you run the whole session underwater, hands-free — start and stop sessions, log dives, and drop markers with the watch's buttons. Apple Watch Series 10 and 11 also track depth, and other Apple Watch models log your sessions with GPS location and heart rate.
```

## What's New (v1.0.30)

```
• Your dive photos and videos are now organized into a "Dive Free" album in Photos, with per-spot and per-session folders.
• Fixed a photo that could close immediately the first time you opened it in a session.
• Spot list now shows how many sessions you've logged at each spot.
```

## URLs

| Field | Value | Notes |
|---|---|---|
| Privacy Policy URL | `https://divefree.software-engineer.ing/privacy` | **Required.** Served by the Worker (`Server/src/index.ts`); live after the next `Server/**` push deploys. |
| Support URL | `https://divefree.software-engineer.ing/support` | **Required.** Served by the Worker (`GET /support` on the apex). |
| Marketing URL | _optional_ | |
| Copyright | `© 2026 Yurko` | |

**Hosting the privacy policy:** served by a `GET /privacy` route on the existing
Cloudflare Worker (`Server/src/index.ts`), bound to the public apex domain and
reachable at `https://divefree.software-engineer.ing/privacy`. Cloudflare Workers
Builds auto-deploys on pushes touching `Server/**`, so the URL goes live once
this change merges. Verify it loads before submitting.

## App Privacy ("nutrition label")

The Strava FIT export sends GPS coordinates, heart rate, and depth/duration
off-device (to Strava, at the user's request), so the **recommended answer is to
declare that data** — App Review runs network analysis and would flag observable
egress against a "Data Not Collected" label. Declare exactly:

- **Location → Precise Location**
- **Health & Fitness → Health** (heart rate) and **Fitness** (depth, duration, calories)

For each: used for **App Functionality** only; **not** linked to the user's
identity; **not** used for tracking.

Do **not** declare anything else — there are no analytics/ads/tracking SDKs, and
photos and voice notes never leave the device (Strava's API can't accept photos).

(The empty `NSPrivacyCollectedDataTypes` in `PrivacyInfo.xcprivacy` is fine: that
array aggregates per-SDK privacy reports; the App Store Connect label is the
authoritative per-app declaration and need not mirror it.)

## Age rating

Answer **None** to every content descriptor → **4+**. (No objectionable content;
"not a dive computer / never dive alone" disclaimer is in the description.)

## App Review notes (paste into "Notes")

```
DiveFree is a recreational freediving/snorkeling LOGBOOK, not a dive computer. It provides no decompression, dive-planning, or safety guidance (see the disclaimer in the app description).

Underwater depth uses CMWaterSubmersionManager with the Shallow Depth and Pressure entitlement (com.apple.developer.submerged-shallow-depth-and-pressure, ~6 m max). Depth and automatic dive detection require an Apple Watch Ultra physically submerged in water and CANNOT be exercised in the simulator or in a dry paired-device review. Everything else — session history, depth charts, dive-spot maps, photo/video attachments, voice notes, and Strava export — is fully testable on the surface. A short demo video of an underwater session can be provided on request.

HealthKit is used to save dive sessions as workouts and read the user's own workout/heart-rate data. Health data is never used for advertising. It stays on device except that, if the user exports a session to Strava, the activity (which can include heart rate, depth, duration, and a GPS track) is sent to Strava at the user's explicit request.

Strava export is optional and user-initiated via OAuth. The OAuth client secret is held by a stateless relay (a Cloudflare Worker) so it is never embedded in the app; the relay stores no user data. No demo account is required — Strava is not needed to review the app.
```

## Pre-submission checklist

- [ ] Privacy Policy URL live and entered
- [ ] Support URL live and entered
- [ ] Screenshots uploaded: iPhone 6.9" + 6.5"; Apple Watch (Ultra) — see below
- [ ] App Privacy answers entered (and consistent with the privacy manifest)
- [ ] Age rating completed (4+)
- [ ] Export compliance — already pre-cleared via `ITSAppUsesNonExemptEncryption=false`
- [ ] Build uploaded (v1.0.30) and attached to the version
- [ ] Review notes pasted

### Screenshots (you must capture these)
- iPhone 6.9" (required) and 6.5" — e.g. session list, a dive's depth chart,
  the spot map, a session gallery.
- Apple Watch — the live underwater session screen and the post-dive summary.
- Capture on a real device or the simulator (⌘S in Simulator). Apple Watch
  marketing screenshots can be taken from the Watch simulator.
