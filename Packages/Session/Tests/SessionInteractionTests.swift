import Foundation
import Testing
import Domain
@testable import Session

@Suite("SessionInteraction")
struct SessionInteractionTests {
    private let kinds = EventKind.builtInMarkerKinds // note, wildlife, hazard, photo

    @Test("menu is Voice Note, the default marker first, the rest, then End")
    func menuOrder() {
        let interaction = SessionInteraction(kinds: kinds, defaultMarkerID: EventKind.wildlife.rawValue)
        #expect(interaction.menuItems.first == .voiceNote)
        #expect(interaction.menuItems.last == .end)
        guard case .mark(let kind) = interaction.menuItems[1] else { Issue.record("expected a marker"); return }
        #expect(kind.id == EventKind.wildlife.rawValue)
    }

    @Test("starts focused on the default marker")
    func defaultFocus() {
        let interaction = SessionInteraction(kinds: kinds, defaultMarkerID: EventKind.hazard.rawValue)
        guard case .mark(let kind) = interaction.focusedAction else { Issue.record("expected a marker focus"); return }
        #expect(kind.id == EventKind.hazard.rawValue)
    }

    @Test("focus clamps to the menu bounds")
    func focusClamps() {
        var interaction = SessionInteraction(kinds: kinds, defaultMarkerID: EventKind.note.rawValue)
        interaction.focus(-5)
        #expect(interaction.focusedIndex == 0)
        interaction.focus(999)
        #expect(interaction.focusedIndex == interaction.menuItems.count - 1)
    }

    @Test("surface confirm places the focused marker")
    func surfaceConfirmMarker() {
        var interaction = SessionInteraction(kinds: kinds, defaultMarkerID: EventKind.wildlife.rawValue)
        #expect(interaction.confirmFocused() == .placeMarker(MarkerKind(.wildlife)))
    }

    @Test("surface confirm on End arms the dialog instead of ending")
    func surfaceConfirmEndArms() {
        var interaction = SessionInteraction(kinds: kinds, defaultMarkerID: EventKind.note.rawValue)
        interaction.focus(interaction.menuItems.count - 1) // End
        #expect(interaction.confirmFocused() == .none)
        #expect(interaction.pendingEndConfirmation)
    }

    @Test("submerged Action button places the focused marker, or the default on a non-marker")
    func submergedActionButton() {
        var interaction = SessionInteraction(kinds: kinds, defaultMarkerID: EventKind.wildlife.rawValue)
        #expect(interaction.actionButton(isSubmerged: true, defaultMarker: MarkerKind(.note)) == .placeMarker(MarkerKind(.wildlife)))
        interaction.focus(0) // Voice Note (non-marker)
        #expect(interaction.actionButton(isSubmerged: true, defaultMarker: MarkerKind(.note)) == .placeMarker(MarkerKind(.note)))
    }

    @Test("Action + side toggles a manual dive")
    func actionSideManualDive() {
        var interaction = SessionInteraction(kinds: kinds, defaultMarkerID: EventKind.note.rawValue)
        #expect(interaction.actionSide() == .toggleManualDive)
    }

    @Test("end dialog: Action + side confirms, Action button cancels")
    func endDialogMapping() {
        var armed = SessionInteraction(kinds: kinds, defaultMarkerID: EventKind.note.rawValue)
        armed.focus(armed.menuItems.count - 1)
        _ = armed.confirmFocused()
        #expect(armed.pendingEndConfirmation)

        var cancel = armed
        #expect(cancel.actionButton(isSubmerged: false, defaultMarker: MarkerKind(.note)) == SessionInteraction.Effect.none)
        #expect(!cancel.pendingEndConfirmation)

        var confirm = armed
        #expect(confirm.actionSide() == .end)
        #expect(!confirm.pendingEndConfirmation)
    }

    @Test("setMenu rebuilds the menu and clamps focus")
    func setMenuClamps() {
        var interaction = SessionInteraction(kinds: kinds, defaultMarkerID: EventKind.note.rawValue)
        interaction.focus(interaction.menuItems.count - 1)
        interaction.setMenu(kinds: [], defaultMarkerID: EventKind.note.rawValue) // → [voiceNote, end]
        #expect(interaction.focusedIndex <= interaction.menuItems.count - 1)
        #expect(interaction.menuItems.count == 2)
    }
}
