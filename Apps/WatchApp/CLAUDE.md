# WatchApp

`SessionCoordinator` is the application-layer glue: it owns `WorkoutController` (HealthKit), `SessionManager` (from the `Session` package — capture + persistence), and `SyncManager` (watch→phone). `SessionRootView` binds to it via `@Environment`.

Call order: `start()` → `workout` auth/start → `sessionManager.startSession()`. `stop()` → `workout.end()` → `sessionManager.stopSession()` (persists to SwiftData) → `sync.send()`.

`DiveFreeWatchApp` owns the `DiveStore` and passes its `mainContext` into `SessionCoordinator`. The watch now persists sessions locally **and** sends them to the phone.

## Underwater interaction model

Water Lock disables the touchscreen mid-dive, so the active-session UI is driven entirely by the **Digital Crown** and the **Action button** — no taps required.

- **Crown** moves the highlight in a single-action carousel (`SessionCoordinator.menuItems` = one entry per `EventKind` + custom kinds, then End Session) via `focus(_:)`. The Crown works at the surface **and** underwater (Water Lock leaves it active), and only *navigates* — nothing fires on its own (no timeout). A fresh session starts focused on the diver's **default marker** (Settings → Default marker, `AppStorage("defaultMarkerKindID")`).
- **Action button** → `AddMarkerIntent` → `LiveSessionRegistry.shared.coordinator?.handleActionButton()`. Context-sensitive: **submerged** it places the Crown-focused marker — or the default marker if the diver is parked on End (the Action button never ends a dive underwater; that's the Action + side dual-click); **on the surface** it runs `confirmFocused()` on the highlighted item (a marker, or End → arms the confirmation).
- **On the surface, a screen tap is an equivalent confirm** (`confirmFocused()`, guarded by `!isSubmerged`) — this is the touch fallback when no Action button is assigned, or on a watch without one. Underwater the screen is water-locked, so stray touches are inert.
- The action **selector** is shown whenever the screen is on (surface and underwater, hidden only in AOD/luminance-reduced) so the diver always sees what the Action button will drop.
- **Action + side dual-click** → Pause/Resume workout intents → `handleEndGesture()`: while active it arms then confirms End (touch-free underwater end); on the post-dive summary it maps to **Done** (`dismissSummary()`).
- Submersion is auto-detected via `isSubmerged` (`SessionManager.currentDiveStart != nil`, i.e. depth below the detector's surface threshold) — there is no manual mode toggle.

`LiveSessionRegistry` (in `AddMarkerIntent.swift`) holds a weak reference to the running coordinator so the Action-button intent routes into the live session rather than a fresh app context. `openAppWhenRun = false` keeps the workout screen foregrounded.

**One-time setup (Watch Ultra):** the diver must assign the action under **Settings → Action Button → App → Dive Free** (third-party Action-button actions are App Intents and cannot be claimed programmatically).

> Foreground delivery of the Action-button press to the already-running app is the documented App Intents pattern but is unverified on-device; if a press launches a fresh process instead, fall back to an app-group store or `NSUserActivity` hand-off.
