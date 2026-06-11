# WatchApp

`SessionCoordinator` is the application-layer glue: it owns `WorkoutController` (HealthKit), `SessionManager` (from the `Session` package — capture + persistence), and `SyncManager` (watch→phone). `SessionRootView` binds to it via `@Environment`.

Call order: `start()` → `workout` auth/start → `sessionManager.startSession()`. `stop()` → `workout.end()` → `sessionManager.stopSession()` (persists to SwiftData) → `sync.send()`.

`DiveFreeWatchApp` owns the `DiveStore` and passes its `mainContext` into `SessionCoordinator`. The watch now persists sessions locally **and** sends them to the phone.

## Underwater interaction model

Water Lock disables the touchscreen mid-dive, so the active-session UI is driven entirely by the **Digital Crown** and the **Action button** — no taps required.

- **Crown** moves the highlight in a single-action carousel (`SessionCoordinator.menuItems` = one entry per `EventKind`, then End Session) via `focus(_:)`. The Crown only *navigates* — nothing fires on its own (no timeout).
- **Action button** → `AddMarkerIntent` → `LiveSessionRegistry.shared.coordinator?.handleActionButton()` is the sole confirm. Context-sensitive: **submerged** drops a `.note` marker (the menu can't be confirmed underwater, so End Session is surface-only — you can't accidentally end a dive mid-water); **on the surface** it runs `confirmFocused()` on the highlighted carousel item (so the diver re-picks a marker kind with the Crown and places it with the button, or scrolls to End and confirms).
- Submersion is auto-detected via `isSubmerged` (`SessionManager`: depth below the detector's surface threshold) — there is no manual mode toggle.

`LiveSessionRegistry` (in `AddMarkerIntent.swift`) holds a weak reference to the running coordinator so the Action-button intent routes into the live session rather than a fresh app context. `openAppWhenRun = false` keeps the workout screen foregrounded.

**One-time setup (Watch Ultra):** the diver must assign the action under **Settings → Action Button → App → Dive Free** (third-party Action-button actions are App Intents and cannot be claimed programmatically).

> Foreground delivery of the Action-button press to the already-running app is the documented App Intents pattern but is unverified on-device; if a press launches a fresh process instead, fall back to an app-group store or `NSUserActivity` hand-off.
