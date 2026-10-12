# Plan 5 — Review request after ten logged dives

Status: implemented. No badges or rewards for reviews. The Domain eligibility policy and the app-layer persisted request gate have automated tests for threshold, cancellation, changing eligibility, and suppression. Physical-device presentation remains a release check.

## Goal

Celebrate the user's tenth logged dive and invite an honest App Store review at a natural break in the experience. Count detected dives, not sessions. Do not infer that logging ten dives means the user likes the app.

Milestone text: **Congratulations on your 10th dive!**

Use Apple's standard review dialog for the invitation itself. Its wording cannot be customised. Do not add a custom modal review prompt, a star selector, or a positive/negative feedback filter. Apple prohibits custom review prompts and incentivised feedback. The system decides whether to display its dialog and provides no submission or star-rating result.

Sources:
- https://developer.apple.com/app-store/review/guidelines/ (§5.6.1 App Store Reviews)
- https://developer.apple.com/documentation/storekit/requestreviewaction
- https://developer.apple.com/documentation/storekit/requesting-app-store-reviews

## Implementation

- Use the existing completed logbook's total detected-dive count. On iPhone/iPad, trigger once when the total reaches or exceeds 10 and the user views a completed session detail after recording/sync. Imports can increase the count; do not trigger on launch, during backup restore, or while a Watch session is active.
- Show a small, dismissible congratulations banner in the session detail. For a session crossing the threshold, use “Congratulations on your 10th dive!” even if that session contains multiple dives. Localise it in all eight app languages.
- After the banner has appeared and the user is idle for two seconds, call SwiftUI's `requestReview`. Cancel the pending call if the view disappears, the app becomes inactive, a session starts, or another sheet/alert is presented. The platform supplies the actual review invitation.
- Persist a local `tenDiveReviewAttempted` flag only when calling `requestReview`. After that, do not repeat this milestone request, even if Apple's dialog was suppressed. Deleting/restoring dives must not reset the flag. Skipping/cancelling before the API call leaves the milestone eligible for the next appropriate session-detail visit.
- Existing users with more than ten dives are eligible on their next completed-session detail visit. No minimum time-in-app rule or app-version rule is needed for this one-time milestone.
- Add a persistent, neutral **Write a Review** link in Settings using `https://apps.apple.com/app/id6779426563?action=write-review`. This is a separate user-initiated route, not a custom rating dialog. It does not award anything or change the milestone eligibility.
- Suppress the milestone and review call in screenshot/demo mode. Never track whether a review was submitted, ask the user to report their stars, or gate features on any review action. Supporter purchases remain disabled.

## Acceptance checks

Test totals of 9, 10, and 11 dives; multiple dives in one session; ten sessions containing fewer than ten dives; an existing logbook above the threshold; and duplicate Watch transfers. Test that active sessions, restore, background state, modal presentations, and screenshot mode cannot prompt. Verify the attempt flag survives relaunch and logbook deletion/restore. Confirm cancelled scheduling does not mark an attempt, while a suppressed StoreKit request does. Verify VoiceOver reads the milestone and the Settings link opens the verified listing. TestFlight suppresses the system dialog, so verify presentation in a development build.
