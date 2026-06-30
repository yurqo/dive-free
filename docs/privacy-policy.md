# DiveFree Privacy Policy

_Effective date: June 25, 2026_

> The live version of this policy is served at
> <https://divefree.software-engineer.ing/privacy> by the Cloudflare Worker
> (`Server/src/index.ts`). Keep the two copies in sync.

DiveFree ("the app," "we," "us") is a freediving and snorkeling session logger
for Apple Watch and iPhone. The app is designed to keep your data on your own
devices and under your control. This policy explains what data the app handles
and where it goes.

## Summary

- **Your dive data stays on your devices.** We do not operate a server that
  stores your personal data, and we have no access to your dives, health data,
  location, photos, or voice notes.
- **Optional iCloud sync.** If you turn on iCloud Sync, your dive log syncs across
  your own devices through your private iCloud (Apple's CloudKit). It stays in your
  iCloud account under your Apple ID; we have no access to it.
- **No analytics, advertising, or third-party tracking SDKs.** The app does not
  track you across apps or websites.
- Data leaves your device only when **you** choose to share it (for example,
  exporting a dive to Strava) or through Apple's own system services.

## What the app handles

### Health & fitness
With your permission, the app reads and writes workout data through Apple
HealthKit to record your dive sessions as workouts. This data is stored by Apple
Health on your device; we never receive it and never use it for advertising or
marketing. It is not shared with third parties — except that, if you choose to
export a session to Strava, the exported activity can include your heart rate
(see Strava below).

### Location
With your permission, the app records where your dives happen so it can group
them into dive spots and show them on a map. Coordinates are stored on your
device. To turn coordinates into place names, the app uses Apple's geocoding
service, which sends coordinates to Apple under Apple's privacy policy. Location
is never used to track you.

### Photos & videos
With your permission, the app references photos and videos from your photo
library to attach them to dive spots and sessions, and can organize them into a
"Dive Free" album. The app references your existing library items — it does not
upload them anywhere, and they remain in your photo library.

### Voice notes
Voice notes you record are stored as audio files on your device.

### iCloud sync (optional)
If you turn on **iCloud Sync** (Settings → iCloud), the app syncs your dive log —
sessions, dives, markers, spots, and photo references — across your own devices
using Apple's CloudKit, stored in your **private** iCloud database. This data
lives in your iCloud account under your Apple ID; we operate no server for it and
have no access to it. It is governed by
[Apple's privacy policy](https://www.apple.com/legal/privacy/). Turn iCloud Sync
off in Settings to keep your data only on the local device.

_(Applies from app version 1.1.0. The **live** policy at the URL above and the App
Store privacy details are updated when 1.1.0 is released publicly — deferred while
1.0.x is in review.)_

### Strava (optional)
If you connect Strava, the app exports the dives you choose as Strava
activities. Sign-in uses Strava's OAuth; it is brokered by a stateless relay we
operate **solely** to keep Strava's client secret off your device — the relay
stores no user data or tokens. Your Strava access tokens are stored on your
device. Activity data you export (such as the time, duration, depth, location,
and heart rate of the dive) is sent to Strava and is then governed by
[Strava's privacy policy](https://www.strava.com/legal/privacy).

## What we do NOT do

We do not collect, transmit to ourselves, or sell your personal data. The app
contains no analytics, advertising, crash-tracking SDKs, or device
fingerprinting.

## Retention & deletion

Because your data lives on your device, you control it. Deleting a session,
photo reference, or the app removes the associated data from the app. Health
data is managed in Apple Health, photos in the Photos app, and exported
activities in Strava.

## Children

The app is not directed at children under 13 and does not knowingly collect
data from them.

## Changes

We may update this policy; material changes will be reflected by the effective
date above.

## Contact

Questions about this policy: **dive-free@software-engineer.ing**
