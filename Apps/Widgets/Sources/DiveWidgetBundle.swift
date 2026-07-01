import WidgetKit
import SwiftUI

/// The app's widget bundle. Currently just the in-progress-dive Live Activity
/// (#118); home-screen widgets (#113) would join here.
@main
struct DiveWidgetBundle: WidgetBundle {
    var body: some Widget {
        DiveLiveActivity()
    }
}
