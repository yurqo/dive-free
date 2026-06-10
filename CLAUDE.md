# DiveFree — Claude Code guidance

## Build verification

### watchOS platform-gated code
After editing any file containing `#if os(watchOS)` blocks, build the Watch app target before pushing. The `Sensors` (and other) test schemes target iOS only and never compile watchOS-guarded code, so errors there are invisible until CI runs.

```
xcodebuild build \
  -workspace DiveFree.xcworkspace \
  -scheme DiveFreeWatch \
  -destination "generic/platform=watchOS Simulator" \
  CODE_SIGNING_ALLOWED=NO \
  EXCLUDED_ARCHS=x86_64
```
