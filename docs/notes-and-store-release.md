# Notes and App Store release validation

## Implemented

Notes use the existing marker icon/type and `text` description plus optional title, transcript, and summary. Phone/iPad review transcription or Apple Intelligence suggestions before applying them. The Watch edits title/type and can remove a recording or delete a note. Both editors save drafts explicitly. Deleting a note leaves session photos intact.

`NoteMutationRecord` is a private-CloudKit-compatible edit journal. Deleting a note prunes its historical text while retaining deletion and audio-removal tombstones. WatchConnectivity transfers individual operations and acknowledges them only after persistence. The journal is the durable outbox and tombstone source. Reconciliation orders revisions by timestamp and UUID per changed field; note deletion and original-recording removal remain permanent. The phone forwards operations originating on iPad after CloudKit delivery. Old session payloads and backups decode without the new fields. Backups also retain the edit journal.

Transcription uses SpeechAnalyzer on supported iOS 26+ devices/languages, with on-device-only SFSpeechRecognizer fallback. Summaries use the available on-device Foundation Models model. Original recordings remain until explicitly removed. No paid AI API is required.

Store copy describes all current functionality as free and commits to keeping core dive recording and logbook features free forever. The friendly English wording is: “Made for the love of diving. All app features are free to use. Core dive recording and logbook features will always be free.” Supporter purchases remain disabled and are not advertised.

## Local marketing commands

- `ruby Scripts/validate-metadata.rb`: validate all nine locales locally without credentials.

- `Scripts/screenshots.sh`: capture both platforms, then generate the iPhone/Watch and iPad/iPhone/Watch heroes in each language.
- `Scripts/screenshots.sh --compose-only`: regenerate composites from existing complete captures without launching simulators.
- `Scripts/screenshots.sh --compose-only --locale en`: render only the English drafts while finalising the design.
- `bundle exec fastlane ios stage_preview`: stage localized screenshots and generate an HTML contact sheet without accessing App Store Connect.
- `bundle exec fastlane ios validate`: existing App Store precheck. This requires App Store connectivity/credentials and is separate from local character/byte validation.

The five original screenshots remain in each iPhone/iPad set, including `02-detail` (session summary). Additional first-position heroes show iPhone + Watch (`00-watch-and-iphone`) and iPad + iPhone + Watch (`00-ipad-iphone-watch`). Phone and iPad screens inside the heroes come from separate individual-dive attachments, `90-hero-dive-profile`; Fastlane excludes these raw inputs from store staging. Both platforms therefore publish six images each, while the dedicated Watch set retains five.

The live Watch hero freezes the first featured dive at 18 seconds, reading depth, heart rate, temperature, location, marker count, and session elapsed from the same saved fixture used by phone/iPad charts. The Watch system clock is captured at 5:02, matching the featured dive’s 17:02 start; phone/iPad show their later review time. The `capture-watch-live.py` helper uses a temporary simulator Carousel timezone offset, restored afterward, because watchOS rejects `simctl status_bar` overrides. It checks the clock with native Vision OCR and fails rather than exporting a mismatched clock. `WATCH_SCREENSHOT_TIME` defaults to 17:02; adjust it when changing the fixture’s displayed start time. No clock pixels are redrawn. At that instant the depth is 2.88 m (displayed as 2.9 m), heart rate 79 bpm, temperature 28°C, and session elapsed 2:18; the note at 30 seconds has not been added yet. Phone/iPad show the completed 1:30 dive, with max depth 4.5 m. Ordinary Debug and Release recording do not use this snapshot.

All screenshot capture uses metric units regardless of saved simulator preferences or region. Simulated demo profiles contain an uneven descent, a brief bottom phase, and a slower ascent. Heart-rate samples every three seconds vary throughout each dive and surface interval. Receipts hash every source, its manifest, the renderer, and output. Staging rejects missing or stale heroes. Generated images stay under the existing ignored `screenshots/` and `fastlane/screenshots/` directories. During design iteration, only English drafts are rendered; regenerate and validate every locale after design approval.

The phone has equal left, right, and bottom frame margins (78.5 px). The Watch sits fully over the phone's lower-right screen area with equal right and bottom insets, and screen sizes scaled using the source devices' 460/326 ppi. Both screenshots retain their native aspect ratios; captions use a compact header above the devices. Phone clipping follows the continuous corner profile of the captured iPhone 17 Pro Max (Xcode's display mask), rather than a circular radius. Watch clipping follows the complete 36-segment continuous outline from the Apple Watch Ultra 3 (49mm) display mask at 422 × 514 px; its previous approximation used a circular radius of 19% of its width. Both silhouettes have a uniform 14 px border. Apple's [iPhone 18 Pro specifications](https://www.apple.com/iphone-18-pro/specs/) confirm rounded corners but do not publish a numeric radius; this renderer does not claim an exact iPhone 18 profile.

## Verification performed

Direct Swift 6 type checks passed for both app targets and the new Domain/Persistence/Sync tests. Native in-memory SwiftData checks passed for duplicate and out-of-order edits, edits arriving before sessions, independent field merging, audio removal, legacy decoding, backup restore, deletion precedence, and photo retention. All nine metadata locales passed length/keyword limits. All sixteen final heroes passed dimensions, opacity, source-hash checks, and repeated-output determinism; local staging produced 153 screenshots across nine App Store locales. Long German and Ukrainian phone captions fit on one complete line. Server TypeScript and shell/Ruby syntax checks passed.

Normal Tuist generation, Xcode builds, and the Xcode test runner remain blocked by the unaccepted local Xcode licence. Direct type checks are not a substitute for those builds or physical-device validation.

All 96 iPhone/iPad source captures and 40 Watch captures were refreshed across eight languages using temporary simulator apps built directly from the current Swift sources, with compiled resources copied from the previously installed simulator builds. Separate preview bundle IDs preserve the existing installed apps. All five original phone/iPad screens remain, including both `02-detail` summaries. Each set publishes six phone images, six tablet images, and five Watch images; separate raw hero inputs are excluded.

Native SwiftData fixture checks verified the 18-second sample against the completed dive: 2.88 m, 79 bpm, 19°C, 2:18 session elapsed, zero markers before the note at 30 seconds, a complete surface-to-surface 90-second profile, and max depth 4.5 m. The reusable native-clock capture helper passed a simulator run and restored its environment afterward. Both hero contact sheets were inspected across all eight capture languages. Direct Swift 6 compilation and screenshot-test type checking passed; XCUITest execution remains unverified until the Xcode licence is accepted.

## Release gates

Regenerate the project after changing `Project.swift`. Build DiveFree and DiveFreeWatch and run Domain/Persistence/Sync tests. Verify on physical devices: recording arrival, offline edit convergence, iPad relay through CloudKit, speech-language asset download/cancellation, and Apple Intelligence unavailable states. Publish the updated privacy policy alongside the feature release. On 2026-10-03 the final screenshot set was uploaded to the user-created 1.4.0 draft in App Store Connect. All nine locales contain 17 screenshots (six phone, six iPad, five Watch), with both heroes first. A separate API read verified every filename, processing status, source MD5 checksum, count, and hero order; the draft remains PREPARE_FOR_SUBMISSION. Metadata text and app binaries were not uploaded by this screenshot step.

The 40 m work package was cancelled at the user's request. Its request document was removed. The existing 6 m entitlement and depth limit remain.

The fifth work package is implemented: a localized congratulations banner on completed session detail after ten logged dives, followed by Apple's standard review request after two idle seconds. Backgrounding, active recording, restoring, dismissal and modal presentation cancel scheduling. A durable local flag is written only when the API is called; repeated windows and a suppressed system dialog cannot repeat the milestone. Settings includes a neutral Write a Review link. No badges or incentives are used.

## Final implementation checks (2026-10-03)

The dive detector now retains the initial shallow descent and its recent surface baseline, while judging acceptance only on the deep span. Surface waits, abandoned descents, stale readings and noise spikes do not inflate a dive. The live Watch timer uses the same retained onset, with a separate deep-span clock for confirmation. Regression tests cover the missing first three seconds and manual-dive boundaries.

All 432 tests across Domain, Persistence, Session, Sync and the app-layer review gate passed in a native macOS Swift Testing runner. Both iPhone/iPad and Watch source checks passed under Swift 6. This is additional evidence, not a signed Xcode build: Tuist generation still fails at the Xcode licence check. Physical-device speech, Apple Intelligence, offline WatchConnectivity and private CloudKit relay remain unverified. Before distribution, initialize and deploy the added CloudKit note-journal schema and fields to the production environment.

The regular five phone/tablet captures previously had the simulator's black rounded-display mask baked into their corners. All 80 regular captures across eight languages were recaptured with the unmasked rectangular framebuffer and encoded as opaque RGB. The 16 hero images remain byte-identical. Screenshot staging now rejects black corner masks in regular captures, and the XCUITest capture path explicitly uses an opaque app-window image. `opaque-screenshot.swift` converts an unmasked simctl capture from RGBA to RGB. All 153 corrected store images were uploaded to the 1.4.0 draft; a fresh API read verified processing, source checksums, filenames, counts and hero order for all nine locales.

The nine localized metadata sets and new 1.4.0 release notes were uploaded and independently verified against App Store Connect, including preserved support/privacy URLs. The updated privacy policy was deployed to the existing Cloudflare Worker and checked live. The support-purchase flag remains false. Marketing version is now 1.4.0. The App Store version remains PREPARE_FOR_SUBMISSION, with no new binary uploaded or review submission.

## TestFlight and refreshed assets (2026-10-04)

The release source at `c0625a2` passed normal Xcode CI: Domain, Persistence,
Sensors, Session, review-request, Sync and Strava tests, plus both app builds.
The existing delivery workflow archived, exported and uploaded **1.4.0 (200)**
successfully, tagging `v1.4.0`. App Store Connect independently reported `VALID`
and `IN_BETA_TESTING`; the build was verified in the existing **Me** internal
TestFlight group. All nine TestFlight localizations contain the current release
notes, including the GPS filtering/distance improvements. The App Store release
notes were also uploaded and independently checked in all nine locales.

All 96 iPhone/iPad source captures and 40 Watch captures were refreshed from the
current Swift sources. Regular images retain opaque rectangular edges. Both hero
sets retain the approved layout and matching 18-second dive values, with the native
Watch clock verified at 5:02. Phone/iPad review clocks represent 18:10, with native
locale formatting. All sixteen composites passed repeated-output determinism.

Visual review found a dimmed Portuguese Watch image and summary images captured
during the system launch spinner. Those images were recaptured with longer settling
time; all forty Watch images passed content checks and contact-sheet review.
`validate-watch-screenshot.swift` now rejects loading/dimmed captures during both
capture and staging. The guard was checked against valid content, the captured
dimmed frame, and empty input. Shell/Ruby syntax and Swift script checks passed.

All **153** refreshed store images were uploaded to the 1.4.0 draft. A fresh API
read verified every filename, count, processing state, source checksum, and first
hero position across nine locales. App Store status remains
`PREPARE_FOR_SUBMISSION`; no App Store review submission was made.

The production CloudKit schema check/deployment remains unverified. No management
token is configured, and CloudKit Console requires sign-in. The console is open
for the user to authenticate; confirm the note-journal type and new marker fields
before relying on cross-device note-edit sync. Physical-device testing of the new
speech, intelligence, GPS and offline-sync behaviour remains necessary.

### 2026-10-05 — Screenshot correction in the new App Store draft

The user-created **1.4.2a** draft inherited the old live screenshots. Replaced all
18 iPhone/iPad session-summary images with the validated captures. An independent
API read verified all **153** checksums, processing states, filenames and ordering
across nine locales, with heroes first. The other 135 images and localized
metadata were preserved. This draft remains `PREPARE_FOR_SUBMISSION`, with no
build selected or review submission. The earlier screenshot-only product-page
correction is still `WAITING_FOR_REVIEW`; it has not changed the live page.

CI for `331b898` passed both app builds, the seven test suites, and the note-editor
UI regression on iPhone/iPad. CloudKit production-schema deployment is still
unverified. The reported `CKErrorDomain 2` is a partial-failure wrapper and does
not identify the cause. New marker fields and `NoteMutationRecord` remain the
schema changes to check; no synchronization code defect has been confirmed.
Console inspection is blocked while the Mac is locked, and paired devices are
unavailable for logs. Keep the new draft's version until diagnosis is complete;
the user authorized moving to **1.4.3** if a code correction is needed.

### 2026-10-04 — 1.4.2 note-editor follow-up

Published **1.4.2 (205)** from `9f62052` through the signed TestFlight workflow
(run `37182264664`). Apple reports `VALID` and `IN_BETA_TESTING`, with the build
available in the existing **Me** internal group. The App Store draft is also
**1.4.2**, with build **205** selected and state **PREPARE_FOR_SUBMISSION**.
API reads verified the nine localized release notes in both App Store Connect
and TestFlight, and preservation of all **153** existing screenshots and other
metadata during the version/build change.

The release moves note presentation to the session screen's shared sheet state,
so initial list updates cannot tear down the editor and pending review requests
are deferred while it is open. Transcription selection respects app language,
preferred regional languages and device region, falls back to UK/US English,
and remembers explicit picker choices. Recording-removal and note-deletion
confirmations now anchor to their action buttons. The local marketing-version
floor and all nine release-note headings have been aligned to **1.4.2**.

### 2026-10-05 — submitted App Review notes corrected

After the user submitted **1.4.2 (205)**, App Store Connect reported
**WAITING_FOR_REVIEW**. Replaced the stale review notes referencing 1.3.7 with
version-independent reviewer instructions covering editable notes, local speech
transcription, optional Apple Intelligence summaries, GPS filtering and the
note-editor fixes. Removed the inaccurate "no new permissions" assertion and
described the Speech Recognition permission used by the on-device fallback.
Clarified local storage/private iCloud sync, user-requested exports, the 6 m
depth limit, and that purchases are not offered in this submission.

Updated only the review-detail `notes` field through the App Store Connect API.
A separate read confirmed all **3,831** characters match the local metadata,
contact/demo-account fields remain unchanged, build **205** remains selected,
and the version remains **WAITING_FOR_REVIEW**. No withdrawal, new binary or
resubmission was needed.

### 2026-10-05 — blank store screenshot correction

Version **1.4.2 (205)** is now **READY_FOR_DISTRIBUTION**. The session-summary
capture sometimes photographed the white navigation/launch frame before the
content appeared. The approved upload contained nine blank localized summaries
across iPhone/iPad (including the English screenshots on both devices). All
153 uploaded checksums matched the local files; the earlier integrity checks
therefore confirmed delivery but did not detect the missing screen content.

Recaptured all sixteen summary sources across eight languages, with settling and
content checks, and staged the resulting eighteen App Store locale assets.
All **135 other published images**, including both heroes and all Watch images,
remain byte-identical. Refreshed composition receipts for the changed manifests
without changing the hero artwork. Reviewed a contact sheet of all corrected
summaries and verified dimensions, opacity, completeness and ordering.

The debug navigation waits for its queried session before opening a capture
destination. XCUITest checks that the summary's Total row is visible before
capturing. `validate-ios-screenshot.swift` rejects blank/launch frames at the end
of capture and again before Fastlane staging. It rejects the actual faulty
captures while accepting the complete corrected set, including sparse iPad
Trips screens. Swift 6 compilation of the app and screenshot tests passed via
the local direct compiler; shell/Ruby syntax and staging checks passed.

Prepared a screenshot-only Product Page Optimization correction through Apple's
public API, keeping the existing app version and binary. Draft experiment:
`a7ae5400-a91b-4f94-a553-20239ead16b4`; treatment:
`446db365-1808-4619-afc5-4ba93521f632`. This draft inherits independent copies of
the current assets; only its session summaries were replaced. Apple processed
all eighteen replacements, and fresh API reads verified the full **108**
iPhone/iPad treatment images, exact source checksums, six images per device per
locale, and first-position heroes.

Submitted **only** this experiment in review submission
`dafcf1a4-13a0-4692-9ab1-4e4a5acde4b4`; the API confirmed
**WAITING_FOR_REVIEW**. No app version, new binary or Watch assets were included
in this submission. After approval, apply treatment
`446db365-1808-4619-afc5-4ba93521f632` to the original **1.4.2** product page
using Product Page Optimization (or `POST /v1/appStoreVersionPromotions`).
Approval and that application are still required: no test has been started,
and the live screenshots have not yet been replaced.

### 2026-10-05 — 1.4.2a screenshot-only metadata aligned

The user confirmed that the CloudKit schema correction resolved iCloud sync.
No additional app-code fix or 1.4.3 release is needed for that issue.

Copied promotional text and What's New exactly from approved **1.4.2** into
the user-created **1.4.2a** draft in all nine App Store locales. Replaced its
review notes with screenshot-only instructions explaining the blank session
summary captures and their corrected replacements. Retained the basic dry
Watch demo instructions; the notes describe no new app functionality.

Fresh API reads verified both copied fields in every locale and the complete
796-character review note. All **153** screenshot IDs, filenames, checksums and
ordering, other localized metadata, reviewer contact/demo fields and build
selection were preserved. **1.4.2a** remains **PREPARE_FOR_SUBMISSION** without
a selected build; it was not submitted for review by this metadata update.

### 2026-10-05 — 1.4.3 screenshot correction build prepared

Apple requires a new eligible uploaded build for a new version submission even
when only screenshots change. The user authorized **1.4.3** for both the binary
and App Store draft. Raised `Project.swift`'s marketing-version floor to 1.4.3.
The localized promotional text and What's New remain exactly as approved in
1.4.2, per the user's instruction. The screenshot-only reviewer notes are kept.
No release app functionality or persistence schema has changed since 1.4.2;
the capture fixes affect debug automation and screenshot validation only.

### 2026-10-05 — 1.4.3 (210) delivered and selected

Published **1.4.3 (210)** from `5241cd0` through the signed TestFlight workflow
(run `37296315213`). Archive, IPA export and upload succeeded; Apple reports
**VALID** and **IN_BETA_TESTING**. The workflow tagged the delivered source
**v1.4.3**. Renamed the existing App Store draft (ID
`77ba5469-cce2-45fb-b119-0c3eaad7e5a7`) from **1.4.2a** to **1.4.3** and selected
build **210**. API reads during both operations confirmed preservation of all
**153** screenshot identities, filenames, checksums and ordering, localized
metadata, reviewer notes and contact/demo fields. The draft remains
**PREPARE_FOR_SUBMISSION**; no App Review submission was made by these steps.

Independent verification confirmed TestFlight release notes in all nine locales
and access in the existing **Me** internal group. Fresh reads confirmed selected
build **210**, the corrected screenshot source hashes and ordering, exact copied
1.4.2 promotional text/What's New, and screenshot-only reviewer notes. CI run
`37296311651` passed all seven package suites, both app builds, and first-open
note-editor UI tests on both iPhone and iPad for the delivered source.

### 2026-10-05 — combined 1.4.3 and 1.4.2 release notes

Prepended a short localized **1.4.3** entry (English: "Refreshed App Store
screenshots.") to all nine release-note files, preserving each entire **1.4.2**
section exactly. Updated App Store Connect's What's New and the reviewer sentence
that previously said the whole field was unchanged. Fresh reads verified every
localized text, unchanged promotional text and other metadata, preserved reviewer
contact/demo fields, and **1.4.3 (210)** still in **PREPARE_FOR_SUBMISSION**.
TestFlight's What's New for build **210** was also updated and independently
verified in all nine locales. No binary rebuild or review submission was needed.

### 2026-10-06 — 1.4.3 withdrawn; approved 1.4.2 screenshot correction

The user withdrew the 1.4.3 submission after the screenshot-only correction was
approved. Fresh App Store Connect reads show **1.4.2 (205)** remains
**READY_FOR_DISTRIBUTION**, while **1.4.3 (210)** is **DEVELOPER_REJECTED**.
The original Product Page Optimization review is **COMPLETE**, its experiment
**APPROVED** and started, with 50% test traffic. The corrected treatment had no
promotion timestamp, so approval alone had not made its images the default.
Verified all **108** approved iPhone/iPad images against the corrected local
source checksums across nine locales, with six images per device in order, then
requested promotion of that treatment to the live **1.4.2** product page.

Apple returned HTTP 500 for the promotion request, but fresh reads confirmed
that it had taken effect: treatment `promotedDate` is
`2026-10-05T19:40:39-07:00` (2026-10-06 10:40:39 Singapore time), and the experiment
is **STOPPED**. No duplicate promotion request was made. Independently verified
all **153 live screenshot source hashes and ordering**, unchanged localized
metadata and Watch screenshot identities, live **1.4.2 (205)**, and withdrawn
**1.4.3 (210)**. The corrected images are now applied to the original product
page rather than limited to test traffic.

The user reported a supported-devices row showing only iPhone/iPad. Fresh public
App Store pages for US, Singapore, UK and Ukraine all show **iPhone, iPad, Apple
Watch**. The public compatibility details include **watchOS 11.0 or later**.
The user's captured page likely reflects caching or the prior test variant;
this explanation is an inference, not a confirmed store-rendering cause. No
Watch configuration changes were made.

### 2026-10-06 — 1.4.4 session media header

Implemented the approved session-detail design: an adaptive map/photo grid above
summary rows and the optional saved title beneath it. The map reuses the same
SessionTrackMapView/SessionMapView as Location, including recorded tracks and dive
markers. Tiles open the existing full map and stable photo pager. One, two, three
and four photos fill the available space; additional media stays accessible through
the pager. Missing GPS/photos and empty titles omit their respective elements.
The existing lower-page photo controls, Location map/smoothing toggle, charts and
other details remain available. There is no persistence or CloudKit schema change.

Updated the shared deterministic screenshot session to Jemeluk Beach, Amed; its
Watch snapshot still derives its readings from the same featured dive samples.
The phone screenshot store adds the four supplied underwater photos and a localized
"Reef encounters" title without accessing the user's library or real store. These
JPEG resources are excluded from Release builds. Screenshot tests now wait for all
header photos to load before recording the session summary.

Prepared version 1.4.4, localized release notes and reviewer instructions. CI covers
first-open map/photo presentation, title editing and deleting photos through each
grid size on both iPhone/iPad; captures refresh every language and device. Build,
capture, upload and App Store draft verification are pending at this point.


#### 1.4.4 release verification

Source `9737e75` passed all seven package test suites and both app builds in
[CI run 37432433364](https://github.com/yurqo/dive-free/actions/runs/37432433364).
All six note/media UI tests passed across iPhone 17 Pro Max and iPad Pro 13-inch
(M5), including first-open presentation, title editing, full map/photo viewing,
and deleting five photos through every grid layout. Tests exposed and fixed
portrait images intercepting taps outside their visible cells; map and photo
tiles also expose explicit button accessibility traits.

[Delivery run 37434524799](https://github.com/yurqo/dive-free/actions/runs/37434524799)
archived, verified that screenshot JPEGs were excluded from Release, exported
and uploaded **1.4.4 (223)**. Tag `v1.4.4` identifies the delivered source.
App Store Connect independently reported `VALID` and `IN_BETA_TESTING`, with
build 223 available to the existing **Me** internal group and selected in the
**1.4.4** `PREPARE_FOR_SUBMISSION` draft. All nine App Store and TestFlight
localizations now contain only the 1.4.4 changes and the free-features message;
older 1.4.2 and 1.4.3 sections were removed at the user's request.

All **153** updated screenshots across nine App Store locales uploaded
successfully to the 1.4.4 draft. An independent App Store Connect read verified
each source hash, filename, ordering, and processing state. The six published
images on iPhone and iPad start with their new device heroes; the five Watch
images remain intact. All five existing phone/tablet screens, including the
session summary, remain after the new hero. Localized capture summaries show the
four supplied photos, "Reef encounters," and Jemeluk Beach, Amed.

Staging caught alpha channels in XCTest's otherwise opaque RGBA screenshot files.
The captures were converted losslessly to RGB and their heroes recomposed before
upload. The live 1.4.2 (205) product page, its nine sets of metadata, and all 153
live screenshot identities and hashes were verified unchanged. Reviewer notes and
the 1.4.4 metadata remain in the editable `PREPARE_FOR_SUBMISSION` draft. No App
Store review submission was made.
