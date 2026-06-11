# WatchApp

`SessionCoordinator` is the application-layer glue: it owns `WorkoutController` (HealthKit), `SessionManager` (from the `Session` package — capture + persistence), and `SyncManager` (watch→phone). `SessionRootView` binds to it via `@Environment`.

Call order: `start()` → `workout` auth/start → `sessionManager.startSession()`. `stop()` → `workout.end()` → `sessionManager.stopSession()` (persists to SwiftData) → `sync.send()`.

`DiveFreeWatchApp` owns the `DiveStore` and passes its `mainContext` into `SessionCoordinator`. The watch now persists sessions locally **and** sends them to the phone.

## Underwater interaction model

Water Lock disables the touchscreen mid-dive, so the active-session UI is driven entirely by the **Digital Crown** and the **Action button** — no taps required.

- **Crown** moves the highlight in a single-action carousel (`SessionCoordinator.menuItems` = one entry per `EventKind`, then End Session) via `focus(_:)`. The Crown only *navigates* — nothing fires on its own (no timeout).
- **Action button** → `AddMarkerIntent` → `LiveSessionRegistry.shared.coordinator?.handleActionButton()`. Context-sensitive: **submerged** drops a `.note` marker (the menu can't be confirmed underwater, so End Session is surface-only — you can't accidentally end a dive mid-water); **on the surface** it runs `confirmFocused()` on the highlighted carousel item (so the diver re-picks a marker kind with the Crown and places it with the button, or scrolls to End and confirms).
- **On the surface, a screen tap is an equivalent confirm** (`confirmFocused()`, guarded by `!isSubmerged`) — this is the touch fallback when no Action button is assigned, or on a watch without one. Underwater the screen is water-locked, so stray touches are inert.
- Submersion is auto-detected via `isSubmerged` (`SessionManager.currentDiveStart != nil`, i.e. depth below the detector's surface threshold) — there is no manual mode toggle.

`LiveSessionRegistry` (in `AddMarkerIntent.swift`) holds a weak reference to the running coordinator so the Action-button intent routes into the live session rather than a fresh app context. `openAppWhenRun = false` keeps the workout screen foregrounded.

**One-time setup (Watch Ultra):** the diver must assign the action under **Settings → Action Button → App → Dive Free** (third-party Action-button actions are App Intents and cannot be claimed programmatically).

Once the session is running, the assigned Action-button intent is delivered to the live app in the foreground — the same mechanism Apple's **Stopwatch** (Action button = lap) and **Workout** (Action button = segment) apps rely on; `openAppWhenRun = false` keeps the live screen foregrounded rather than launching a fresh context. Only exercisable on a physical Watch Ultra (the simulator has no Action button).
