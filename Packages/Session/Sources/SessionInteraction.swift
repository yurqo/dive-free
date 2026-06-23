import Foundation
import Domain

/// Pure, dependency-free model of the in-session interaction: the Crown menu,
/// focus, the Action button, Action + side, and the end-confirmation arming.
///
/// `SessionCoordinator` owns one of these and turns the returned `Effect`s into
/// side effects (placing markers, voice notes, toggling a manual dive, ending),
/// keeping the HealthKit / sync / haptics glue out of here so the transitions are
/// fully unit-testable on iOS.
public struct SessionInteraction: Equatable, Sendable {
    /// A single Crown-menu action, top → bottom: Voice Note, the marker kinds,
    /// then End.
    public enum Action: Equatable, Identifiable, Sendable {
        case voiceNote
        case mark(MarkerKind)
        case end

        public var id: String {
            switch self {
            case .voiceNote: "voiceNote"
            case .mark(let kind): "mark.\(kind.id)"
            case .end: "end"
            }
        }

        public var title: String {
            switch self {
            case .voiceNote: "Voice Note"
            case .mark(let kind): kind.label
            case .end: "End Session"
            }
        }

        /// Emoji for marker actions; `nil` for Voice Note / End (which use `systemImage`).
        public var emoji: String? {
            switch self {
            case .voiceNote: nil
            case .mark(let kind): kind.emoji
            case .end: nil
            }
        }

        public var systemImage: String {
            switch self {
            case .voiceNote: "mic.fill"
            case .mark: "mappin"
            case .end: "stop.fill"
            }
        }
    }

    /// What the coordinator should do in response to a button press. Pure data —
    /// no side effects happen inside the machine.
    public enum Effect: Equatable, Sendable {
        case none
        case placeMarker(MarkerKind)
        case toggleVoiceNote
        case toggleManualDive
        case end
    }

    public private(set) var menuItems: [Action]
    public private(set) var focusedIndex: Int
    /// True while the end-session dialog is armed (Crown → End → Action button).
    public private(set) var pendingEndConfirmation: Bool

    public init(kinds: [MarkerKind], defaultMarkerID: String) {
        menuItems = Self.buildMenu(kinds: kinds, defaultMarkerID: defaultMarkerID)
        focusedIndex = Self.defaultFocusIndex(in: menuItems, defaultMarkerID: defaultMarkerID)
        pendingEndConfirmation = false
    }

    /// The currently highlighted action, or `nil` if the menu is empty.
    public var focusedAction: Action? {
        menuItems.indices.contains(focusedIndex) ? menuItems[focusedIndex] : nil
    }

    /// Rebuilds the menu (e.g. when custom markers sync in), clamping focus.
    public mutating func setMenu(kinds: [MarkerKind], defaultMarkerID: String) {
        menuItems = Self.buildMenu(kinds: kinds, defaultMarkerID: defaultMarkerID)
        focusedIndex = min(focusedIndex, max(menuItems.count - 1, 0))
    }

    /// Moves the Crown highlight (clamped). Nothing fires until a button confirms.
    public mutating func focus(_ index: Int) {
        guard !menuItems.isEmpty else { return }
        focusedIndex = max(0, min(index, menuItems.count - 1))
    }

    /// Directly set the armed state (used by the dialog's `isPresented` binding).
    public mutating func setPendingEnd(_ value: Bool) {
        pendingEndConfirmation = value
    }

    /// Surface confirm — the Action button at the surface, or a screen tap. While
    /// the end dialog is armed it cancels it; otherwise it acts on the focused item
    /// (arming End rather than ending immediately).
    @discardableResult
    public mutating func confirmFocused() -> Effect {
        if pendingEndConfirmation { pendingEndConfirmation = false; return .none }
        switch focusedAction {
        case .voiceNote: return .toggleVoiceNote
        case .mark(let kind): return .placeMarker(kind)
        case .end: pendingEndConfirmation = true; return .none
        case nil: return .none
        }
    }

    /// Action button. While the end dialog is armed it **cancels**; submerged it
    /// places the focused marker (or the default when parked on a non-marker);
    /// at the surface it confirms the focused item.
    @discardableResult
    public mutating func actionButton(isSubmerged: Bool, defaultMarker: MarkerKind) -> Effect {
        if pendingEndConfirmation { pendingEndConfirmation = false; return .none }
        if isSubmerged {
            if case .mark(let kind) = focusedAction { return .placeMarker(kind) }
            return .placeMarker(defaultMarker)
        }
        return confirmFocused()
    }

    /// Action + side. While the end dialog is armed it **confirms** the end;
    /// otherwise it toggles a manual dive (start/stop).
    @discardableResult
    public mutating func actionSide() -> Effect {
        if pendingEndConfirmation { pendingEndConfirmation = false; return .end }
        return .toggleManualDive
    }

    // MARK: - Menu construction

    private static func buildMenu(kinds: [MarkerKind], defaultMarkerID: String) -> [Action] {
        let ordered = (kinds.first { $0.id == defaultMarkerID }.map { [$0] } ?? [])
            + kinds.filter { $0.id != defaultMarkerID }
        return [.voiceNote] + ordered.map(Action.mark) + [.end]
    }

    private static func defaultFocusIndex(in menu: [Action], defaultMarkerID: String) -> Int {
        menu.firstIndex {
            if case .mark(let kind) = $0 { return kind.id == defaultMarkerID }
            return false
        } ?? 0
    }
}
