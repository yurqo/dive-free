import Foundation

/// Picks a supported speech locale without letting alphabetical API order
/// choose a dialect. Keep an explicit picker choice; otherwise respect the
/// app language, the user's regional language preferences, and device region.
enum NoteTranscriptionLocale {
    static func select(
        from supported: [Locale],
        savedIdentifier: String = "",
        appLanguage: String = Bundle.main.preferredLocalizations.first ?? "en",
        preferredLanguages: [String] = Locale.preferredLanguages,
        currentLocale: Locale = .current
    ) -> Locale? {
        let supported = supported.sorted { $0.identifier < $1.identifier }
        func exact(_ identifier: String) -> Locale? {
            supported.first { normalized($0.identifier) == normalized(identifier) }
        }
        if let saved = exact(savedIdentifier) { return saved }

        func match(_ identifier: String) -> Locale? {
            let preference = Locale(identifier: identifier)
            let candidates = supported.filter {
                $0.language.languageCode == preference.language.languageCode &&
                (preference.language.script == nil || $0.language.script == preference.language.script)
            }
            guard !candidates.isEmpty else { return nil }
            if let exact = exact(identifier) { return exact }
            if let region = preference.region,
               let regional = candidates.first(where: { $0.region == region }) { return regional }
            if let regional = candidates.first(where: { $0.region == currentLocale.region }) { return regional }
            if preference.language.languageCode?.identifier == "en" {
                let uk = preference.region?.identifier == "GB" || currentLocale.region?.identifier == "GB"
                for identifier in uk ? ["en-GB", "en-US"] : ["en-US", "en-GB"] {
                    if let standard = exact(identifier) { return standard }
                }
                // Never silently select an unrelated English dialect.
                return nil
            }
            let likelyRegion = Locale(identifier: preference.language.maximalIdentifier).region
            return candidates.first(where: { $0.region == likelyRegion }) ?? candidates.first
        }

        let app = Locale(identifier: appLanguage)
        // A region-specific per-app language setting takes precedence.
        if app.region != nil, let result = match(appLanguage) { return result }
        for preference in preferredLanguages where Locale(identifier: preference).language.languageCode == app.language.languageCode {
            if let result = match(preference) { return result }
        }
        if let result = match(appLanguage) { return result }
        // If the app language isn't transcribable, try the user's other languages.
        for preference in preferredLanguages {
            if let result = match(preference) { return result }
        }
        return match("en")
    }

    private static func normalized(_ identifier: String) -> String {
        identifier.replacingOccurrences(of: "_", with: "-").lowercased()
    }
}
