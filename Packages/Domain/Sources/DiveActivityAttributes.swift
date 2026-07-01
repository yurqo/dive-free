#if canImport(ActivityKit)
import ActivityKit
import Foundation

/// Live Activity attributes for an in-progress dive session (#118). Lives in
/// `Domain` (guarded, so the watchOS build — which has no ActivityKit — skips it)
/// so the iPhone app and the widget extension share the **same** type: ActivityKit
/// matches the app's `Activity<DiveActivityAttributes>` against the widget's
/// `ActivityConfiguration(for: DiveActivityAttributes.self)` by type, so a single
/// definition is required.
///
/// The dynamic `ContentState` just carries a `LiveSessionSnapshot`, keeping one
/// source of truth for the live fields across the WatchConnectivity channel and
/// the Live Activity.
public struct DiveActivityAttributes: ActivityAttributes, Sendable {
    public struct ContentState: Codable, Hashable, Sendable {
        public var snapshot: LiveSessionSnapshot
        public init(snapshot: LiveSessionSnapshot) { self.snapshot = snapshot }
    }

    public init() {}
}
#endif
