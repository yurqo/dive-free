import Foundation
import Testing

struct NoteTranscriptionLocaleTests {
    private func selection(_ identifiers: [String] = ["en_AE", "en_GB", "en_US"],
                           saved: String = "", app: String = "en",
                           preferences: [String] = ["en"], region: String = "en_SG") -> String? {
        NoteTranscriptionLocale.select(from: identifiers.map(Locale.init(identifier:)),
                                       savedIdentifier: saved, appLanguage: app,
                                       preferredLanguages: preferences,
                                       currentLocale: Locale(identifier: region))?.identifier
    }

    @Test func genericEnglishDoesNotChooseAlphabeticallyFirstUAE() {
        #expect(selection() == "en_US")
        #expect(selection(region: "en_GB") == "en_GB")
    }
    @Test func preferredDialectWinsOverDeviceRegion() {
        #expect(selection(preferences: ["en-GB"], region: "en_US") == "en_GB")
        #expect(selection(preferences: ["en-US"], region: "en_GB") == "en_US")
    }
    @Test func explicitRegionalAppLanguageWins() {
        #expect(selection(app: "en-GB", preferences: ["en-US"]) == "en_GB")
    }
    @Test func savedPickerChoiceWinsAndNormalizesIdentifiers() {
        #expect(selection(saved: "en-gb", preferences: ["en-US"]) == "en_GB")
        #expect(selection(["en_AU", "en_GB", "en_US"], saved: "en-AU") == "en_AU")
    }
    @Test func unavailableSavedChoiceFallsBackToEnvironment() {
        #expect(selection(saved: "en-AU", preferences: ["en-GB"]) == "en_GB")
    }
    @Test func anotherSupportedRegionalDialectIsRespectedWhenConfigured() {
        #expect(selection(["en_AE", "en_AU", "en_GB", "en_US"], preferences: ["en-AU"]) == "en_AU")
    }
    @Test func standardEnglishFallbackDoesNotDependOnInputOrder() {
        for locales in [["en_AE", "en_GB", "en_US"], ["en_US", "en_AE", "en_GB"]] {
            #expect(selection(locales, preferences: ["en-SG"]) == "en_US")
        }
        #expect(selection(["en_AE", "en_GB"], preferences: ["en-SG"]) == "en_GB")
        #expect(selection(["en_AE", "en_US"], preferences: ["en-GB"]) == "en_US")
    }
    @Test func appLanguageWinsOverSystemLanguage() {
        #expect(selection(["en_US", "fr_FR"], app: "fr", preferences: ["en-US"]) == "fr_FR")
    }
    @Test func unsupportedAppLanguageUsesNextUserLanguage() {
        #expect(selection(["en_AE", "en_GB", "en_US"], app: "uk", preferences: ["uk-UA", "en-GB"]) == "en_GB")
    }
    @Test func nonEnglishUsesRegionAndUsualDialect() {
        #expect(selection(["fr_CA", "fr_FR"], app: "fr", preferences: ["fr"], region: "fr_CA") == "fr_CA")
        #expect(selection(["fr_CA", "fr_FR"], app: "fr", preferences: ["fr"], region: "en_SG") == "fr_FR")
    }
    @Test func languageScriptsAreNotInterchanged() {
        #expect(selection(["zh_CN", "zh_TW"], app: "zh-Hant", preferences: ["zh-Hant"], region: "en_US") == "zh_TW")
    }
    @Test func missingSupportDoesNotSelectAnUnrelatedLanguage() {
        #expect(selection([]) == nil)
        #expect(selection(["ja_JP"]) == nil)
        #expect(selection(["en_AE"]) == nil)
    }
}
