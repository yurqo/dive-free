# WatchApp

`SessionCoordinator` is the application-layer glue: it owns `WorkoutController` (HealthKit), `SessionManager` (from the `Session` package — capture + persistence), and `SyncManager` (watch→phone). `SessionRootView` binds to it via `@Environment`.

Call order: `start()` → `workout` auth/start → `sessionManager.startSession()`. `stop()` → `workout.end()` → `sessionManager.stopSession()` (persists to SwiftData) → `sync.send()`.

`DiveFreeWatchApp` builds the `ModelContainer` (via `DiveStore`) and passes its `mainContext` into `SessionCoordinator`. The watch persists sessions locally **and** sends them to the phone.

## Screenshot mode (DEBUG only)

`WatchScreenshotMode` boots the app into ONE screen for App Store capture:
`--screenshot-demo --screenshot-screen <NN-slug>` → in-memory store seeded with
`DemoData` (Persistence, shared with the iPhone screenshots) and, for `01-live`, a
`SessionManager` fed by a scripted depth profile so the live screen renders without
HealthKit or a submersion sensor. There is no XCTest on watchOS, so this is how
`Scripts/screenshots.sh --watch` drives the app — it cannot tap anything. Adding a
screen means adding a `Screen` case AND the matching `WATCH_SCREENS` entry.

## Underwater interaction model

Water Lock disables the touchscreen mid-dive, so the active-session UI is driven entirely by the **Digital Crown** and the **Action button** — no taps required.

The app **engages Water Lock itself** rather than trusting the swim workout to do it: `SessionCoordinator.enableWaterLock(ifEnabled:)` fires at session start (after the workout is running) and on every false→true submersion, so a diver who Crowns out to interact at the surface is re-locked on the next descent. Both moments are opt-out via `AppStorage("waterLockOnStart")` / `("waterLockOnSubmersion")` — defaulting genuinely ON when unset (`bool(forKey:)` returns false for an absent key, hence the explicit `object(forKey:) == nil` check). `enableWaterLock()` is idempotent, has **no** programmatic disable (the Crown exits it), and is compiled out of the simulator — so this is device-only behaviour.

- **Crown** moves the highlight in a single-action carousel (`SessionCoordinator.menuItems` = one entry per `EventKind` + custom kinds, then End Session) via `focus(_:)`. The Crown works at the surface **and** underwater (Water Lock leaves it active), and only *navigates* — nothing fires on its own (no timeout). A fresh session starts focused on the diver's **default marker** (Settings → Default marker, `AppStorage("defaultMarkerKindID")`).
- **Action button** → `AddMarkerIntent` → `LiveSessionRegistry.shared.coordinator?.handleActionButton()`. Context-sensitive: **submerged** it places the Crown-focused marker — or the default marker if the diver is parked on End (the Action button never ends a dive underwater; that's the Action + side dual-click); **on the surface** it runs `confirmFocused()` on the highlighted item (a marker, or End → arms the confirmation).
- **On the surface, a screen tap is an equivalent confirm** (`confirmFocused()`, guarded by `!isSubmerged`) — this is the touch fallback when no Action button is assigned, or on a watch without one. Underwater the screen is water-locked, so stray touches are inert.
- The action **selector** is shown whenever the screen is on — surface and underwater, and **dimmed rather than hidden** in AOD/luminance-reduced — so the diver always sees what the Action button will drop, including at a wrist-down glance. The surface-recovery target line (`rec M:SS` + ✓) follows the same rule. Both use `SessionRootView.aodDimOpacity`.
- **Action + side dual-click** → Pause/Resume workout intents → `handleEndGesture()`: while active it arms then confirms End (touch-free underwater end); on the post-dive summary it maps to **Done** (`dismissSummary()`).
- Submersion is auto-detected via `isSubmerged` (`SessionManager.currentDiveStart != nil`, i.e. a dive is in progress) — there is no manual mode toggle. The diver counts as submerged from the moment depth crosses the detector's surface threshold on the way down and **stays** submerged through the shallow band on the way up, until depth reaches 0 m or the surface-exit dwell (`surfaceExitDwellSeconds`) expires — so a brief shallow bounce mid-dive does not flip `isSubmerged`.

`LiveSessionRegistry` (in `AddMarkerIntent.swift`) holds a weak reference to the running coordinator so the Action-button intent routes into the live session rather than a fresh app context. `openAppWhenRun = false` keeps the workout screen foregrounded.

**One-time setup (Watch Ultra):** the diver must assign the action under **Settings → Action Button → App → Dive Free** (third-party Action-button actions are App Intents and cannot be claimed programmatically).

> Foreground delivery of the Action-button press to the already-running app is the documented App Intents pattern but is unverified on-device; if a press launches a fresh process instead, fall back to an app-group store or `NSUserActivity` hand-off.
