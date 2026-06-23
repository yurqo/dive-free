import SwiftUI
import Domain

/// Re-renders the wrapped subtree whenever the units preference changes.
///
/// The centralized formatters read `UnitPreference.current` (from `UserDefaults`)
/// rather than taking the preference as a parameter, so plain views wouldn't
/// invalidate when the user changes units — or when a new preference arrives
/// from the iPhone. Observing the `@AppStorage` keys here drives that refresh,
/// cascading to every formatter call in `content`.
private struct UnitsAwareModifier: ViewModifier {
    @AppStorage(UnitPreference.Key.mode) private var mode = ""
    @AppStorage(UnitPreference.Key.depth) private var depth = ""
    @AppStorage(UnitPreference.Key.distance) private var distance = ""
    @AppStorage(UnitPreference.Key.temperature) private var temperature = ""

    func body(content: Content) -> some View { content }
}

extension View {
    /// Refresh this view's depth/distance/temperature displays when the units
    /// preference changes.
    func unitsAware() -> some View { modifier(UnitsAwareModifier()) }
}
