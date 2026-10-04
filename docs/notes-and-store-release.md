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

The live Watch hero freezes the first featured dive at 18 seconds, reading depth, heart rate, temperature, location, marker count, and session elapsed from the same saved fixture used by phone/iPad charts. The Watch system clock is captured at 5:02, matching the featured dive’s 17:02 start; phone/iPad show their later review time. The `capture-watch-live.py` helper uses a temporary simulator Carousel timezone offset, restored afterward, because watchOS rejects `simctl status_bar` overrides. It checks the clock with native Vision OCR and fails rather than exporting a mismatched clock. `WATCH_SCREENSHOT_TIME` defaults to 17:02; adjust it when changing the fixture’s displayed start time. No clock pixels are redrawn. At that instant the depth is 2.88 m (displayed as 2.9 m), heart rate 79 bpm, temperature 19°C, and session elapsed 2:18; the note at 30 seconds has not been added yet. Phone/iPad show the completed 1:30 dive, with max depth 4.5 m. Ordinary Debug and Release recording do not use this snapshot.

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
