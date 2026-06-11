import WatchKit
import Domain

/// Maps `DiveHapticEvent` values to `WKHapticType` and plays them on the
/// current Watch device. Intentionally kept as a simple enum-namespace so it
/// is trivially injectable or stubbed if tests ever need it.
enum DiveHapticPlayer {
    static func play(_ event: DiveHapticEvent) {
        let type: WKHapticType
        switch event {
        case .diveStart:
            type = .start
        case .surface:
            type = .stop
        case .descendMilestone:
            type = .directionDown
        case .ascendMilestone:
            type = .directionUp
        case .markerPlaced:
            type = .success
        }
        WKInterfaceDevice.current().play(type)
    }
}
