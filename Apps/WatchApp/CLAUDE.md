# WatchApp

`SessionCoordinator` is the application-layer glue: starts `WorkoutController` (HealthKit session) and `SensorManager` (depth stream) together, runs `DiveDetector` on stop, and hands the finished `DiveSession` to `SyncManager`.

`WorkoutController` manages the `HKWorkoutSession` + `HKLiveWorkoutBuilder` lifecycle. The workout session keeps the app alive in the background — no separate `WKExtendedRuntimeSession` needed.

Call order: `requestAuthorization()` → `start()` → (session runs) → `stop()`.
