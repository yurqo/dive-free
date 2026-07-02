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

    @Test("setMenu rebuilds the menu, keeping the focused item highlighted")
    func setMenuRebuilds() {
        var interaction = SessionInteraction(kinds: kinds, defaultMarkerID: EventKind.note.rawValue)
        interaction.focus(interaction.menuItems.count - 1) // End
        interaction.setMenu(kinds: [], defaultMarkerID: EventKind.note.rawValue) // → [voiceNote, end]
        #expect(interaction.menuItems.count == 2)
        #expect(interaction.focusedAction == .end) // End survived, so it stays focused
    }

    @Test("submerging hides Voice Note and End, leaving markers only")
    func submergedMenuIsMarkersOnly() {
        var interaction = SessionInteraction(kinds: kinds, defaultMarkerID: EventKind.note.rawValue)
        interaction.setSubmerged(true)
        #expect(!interaction.menuItems.contains(.voiceNote))
        #expect(!interaction.menuItems.contains(.end))
        #expect(interaction.menuItems.allSatisfy { if case .mark = $0 { return true } else { return false } })
        #expect(interaction.menuItems.count == kinds.count)
    }

    @Test("submerging keeps the focused marker; surfacing restores the full menu")
    func submergeSurfacePreservesMarkerFocus() {
        var interaction = SessionInteraction(kinds: kinds, defaultMarkerID: EventKind.note.rawValue)
        // Focus a non-default marker at the surface.
        guard let hazardIndex = interaction.menuItems.firstIndex(of: .mark(MarkerKind(.hazard))) else {
            Issue.record("expected hazard in the surface menu"); return
        }
        interaction.focus(hazardIndex)
        interaction.setSubmerged(true)
        #expect(interaction.focusedAction == .mark(MarkerKind(.hazard))) // survived the descent
        interaction.setSubmerged(false)
        #expect(interaction.menuItems.first == .voiceNote)
        #expect(interaction.menuItems.last == .end)
        #expect(interaction.focusedAction == .mark(MarkerKind(.hazard))) // and the ascent
    }

    @Test("submerging while focused on Voice Note falls back to the default marker")
    func submergeFromNonMarkerFocusesDefault() {
        var interaction = SessionInteraction(kinds: kinds, defaultMarkerID: EventKind.wildlife.rawValue)
        interaction.focus(0) // Voice Note (not in the underwater menu)
        interaction.setSubmerged(true)
        #expect(interaction.focusedAction == .mark(MarkerKind(.wildlife)))
    }

    @Test("submerging clears an armed end")
    func submergeClearsArmedEnd() {
        var interaction = SessionInteraction(kinds: kinds, defaultMarkerID: EventKind.note.rawValue)
        interaction.focus(interaction.menuItems.count - 1) // End
        _ = interaction.confirmFocused()
        #expect(interaction.pendingEndConfirmation)
        interaction.setSubmerged(true)
        #expect(!interaction.pendingEndConfirmation)
    }
}
