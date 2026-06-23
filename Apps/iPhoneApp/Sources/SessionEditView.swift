import SwiftUI
import Domain
import Persistence

/// Edit a session's annotation — title, area name, rating, and notes. Binds
/// directly to the SwiftData record; "Done" saves and dismisses.
struct SessionEditView: View {
    @Bindable var session: SessionRecord
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    // Free-text buffers for the temperature fields, so intermediate input (a lone
    // "-" or trailing ".") isn't fought by a parse-and-rederive binding. Seeded
    // from the record on appear; parsed back into °C as the user types.
    @State private var waterTempText = ""
    @State private var airTempText = ""

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
                conditionsSection
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
            .onAppear {
                waterTempText = displayTemp(session.conditions.waterTemperatureCelsius)
                airTempText = displayTemp(session.conditions.airTemperatureCelsius)
            }
        }
    }

    @ViewBuilder private var conditionsSection: some View {
        Section("Conditions") {
            Picker("Visibility", selection: $session.conditions.visibility) {
                Text("—").tag(WaterVisibility?.none)
                ForEach(WaterVisibility.allCases, id: \.self) { value in
                    Text(value.label).tag(WaterVisibility?.some(value))
                }
            }
            Picker("Current", selection: $session.conditions.current) {
                Text("—").tag(WaterCurrent?.none)
                ForEach(WaterCurrent.allCases, id: \.self) { value in
                    Text(value.label).tag(WaterCurrent?.some(value))
                }
            }
            Picker("Surface", selection: $session.conditions.surface) {
                Text("—").tag(SurfaceCondition?.none)
                ForEach(SurfaceCondition.allCases, id: \.self) { value in
                    Text(value.label).tag(SurfaceCondition?.some(value))
                }
            }
            Picker("Tide", selection: $session.conditions.tide) {
                Text("—").tag(TideStage?.none)
                ForEach(TideStage.allCases, id: \.self) { value in
                    Text(value.label).tag(TideStage?.some(value))
                }
            }
            tempRow("Water temp", text: $waterTempText, into: \.waterTemperatureCelsius)
            tempRow("Air temp", text: $airTempText, into: \.airTemperatureCelsius)
        }
    }

    /// A units-aware temperature entry row: shown/entered in the display unit,
    /// stored in °C. The field uses a free-text buffer so partial input isn't
    /// reverted; empty or unparseable clears the stored value.
    private func tempRow(
        _ title: String,
        text: Binding<String>,
        into keyPath: WritableKeyPath<DiveConditions, Double?>
    ) -> some View {
        HStack {
            Text(title)
            Spacer()
            TextField("—", text: text)
                .multilineTextAlignment(.trailing)
                .keyboardType(.numbersAndPunctuation)
                .onChange(of: text.wrappedValue) { _, newValue in
                    let trimmed = newValue.trimmingCharacters(in: .whitespaces)
                    if let display = Double(trimmed) {
                        session.conditions[keyPath: keyPath] = TemperatureFormat.celsius(fromDisplay: display)
                    } else {
                        // Empty or not-yet-a-number → no stored value.
                        session.conditions[keyPath: keyPath] = nil
                    }
                }
            Text(TemperatureFormat.unitLabel())
                .foregroundStyle(.secondary)
        }
    }

    /// The display-unit string for a stored °C value (whole when integral).
    private func displayTemp(_ celsius: Double?) -> String {
        guard let celsius else { return "" }
        let value = TemperatureFormat.displayValue(celsius)
        return value == value.rounded() ? String(Int(value)) : String(value)
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
