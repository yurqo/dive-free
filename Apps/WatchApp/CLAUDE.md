# WatchApp

`SessionCoordinator` is the application-layer glue: it owns `WorkoutController` (HealthKit), `SessionManager` (from the `Session` package — capture + persistence), and `SyncManager` (watch→phone). `SessionRootView` binds to it via `@Environment`.

Call order: `start()` → `workout` auth/start → `sessionManager.startSession()`. `stop()` → `workout.end()` → `sessionManager.stopSession()` (persists to SwiftData) → `sync.send()`.

`DiveFreeWatchApp` owns the `DiveStore` and passes its `mainContext` into `SessionCoordinator`. The watch now persists sessions locally **and** sends them to the phone.
