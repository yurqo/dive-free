# Sensors package

`SensorManager` (`@Observable`, `@MainActor`) owns a `DepthProvider` and publishes `currentDepthMeters`. `makeDepthProvider()` returns `WaterSubmersionDepthProvider` when `CMWaterSubmersionManager.waterSubmersionAvailable`, otherwise `MockDepthProvider`.

## watchOS build rule

**After any `#if os(watchOS)` change, build `DiveFreeWatch` before pushing** — test targets are iOS-only and never compile watchOS-gated code:

```sh
xcodebuild build -workspace DiveFree.xcworkspace -scheme DiveFreeWatch \
  -destination "generic/platform=watchOS Simulator" \
  CODE_SIGNING_ALLOWED=NO EXCLUDED_ARCHS=x86_64 | xcbeautify
```

## Testing watchOS-only code

All test targets build for iOS only (`Project.swift`). To keep `#if os(watchOS)` logic testable, extract pure transform functions outside the guard (e.g. `makeDepthSample(depth:date:)`) so the iOS test target can reach them.
