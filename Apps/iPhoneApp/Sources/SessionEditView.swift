import SwiftUI
import Persistence

/// Edit a session's annotation — title, area name, rating, and notes. Binds
/// directly to the SwiftData record; "Done" saves and dismisses.
struct SessionEditView: View {
    @Bindable var session: SessionRecord
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        NavigationStack {
            Form {
                Section("Title") {
                    TextField("Optional", text: text(\.title))
                }
                Section {
                    TextField("Area name", text: areaText)
                } header: {
                    Text("Area")
                } footer: {
                    Text("Overrides the automatic location name. Once edited, it won't be replaced automatically.")
                }
                Section("Rating") {
                    StarRating(rating: session.rating ?? 0) { value in
                        session.rating = value == 0 ? nil : value
                    }
                }
                Section("Notes") {
                    TextField("Optional", text: text(\.notes), axis: .vertical)
                        .lineLimit(3...10)
                }
            }
            .navigationTitle("Edit Session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        try? modelContext.save()
                        dismiss()
                    }
                }
            }
        }
    }

    /// A `String` binding over an optional record field; empty maps back to `nil`.
    private func text(_ keyPath: ReferenceWritableKeyPath<SessionRecord, String?>) -> Binding<String> {
        Binding(
            get: { session[keyPath: keyPath] ?? "" },
            set: { session[keyPath: keyPath] = $0.isEmpty ? nil : $0 }
        )
    }

    /// Area-name binding that also flags the name as user-edited so automatic
    /// reverse-geocoding won't overwrite it (even if cleared).
    private var areaText: Binding<String> {
        Binding(
            get: { session.locationName ?? "" },
            set: {
                session.locationName = $0.isEmpty ? nil : $0
                session.locationNameEdited = true
            }
        )
    }
}

/// Five-star rating. Read-only when `onSet` is nil; otherwise tappable — tapping
/// the current rating clears it (sets 0).
struct StarRating: View {
    let rating: Int
    var onSet: ((Int) -> Void)? = nil

    var body: some View {
        HStack(spacing: 3) {
            ForEach(1...5, id: \.self) { index in
                let filled = index <= rating
                Image(systemName: filled ? "star.fill" : "star")
                    .foregroundStyle(filled ? .yellow : .secondary)
                    .contentShape(Rectangle())
                    .onTapGesture { onSet?(index == rating ? 0 : index) }
            }
        }
        // Read-only (no onSet): let taps fall through to an enclosing
        // NavigationLink/row instead of being swallowed by the gesture.
        .allowsHitTesting(onSet != nil)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Rating")
        .accessibilityValue(rating == 0 ? "Unrated" : "\(rating) of 5")
    }
}
