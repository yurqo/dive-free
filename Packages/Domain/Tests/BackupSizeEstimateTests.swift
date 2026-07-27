import Foundation
import Testing
@testable import Domain

@Suite("BackupSizeEstimate")
struct BackupSizeEstimateTests {
    @Test("total is the sum of the baseline and every category")
    func totalSumsAllCategories() {
        let estimate = BackupSizeEstimate(base: 1_000, voiceNotes: 2_000, photos: 3_000, videos: 4_000)
        #expect(estimate.total == 10_000)
    }

    @Test("an empty estimate totals zero")
    func emptyIsZero() {
        let estimate = BackupSizeEstimate()
        #expect(estimate.total == 0)
        #expect(estimate.base == 0)
        #expect(estimate.voiceNotes == 0)
        #expect(estimate.photos == 0)
        #expect(estimate.videos == 0)
    }

    @Test("total(with:) counts the baseline plus only the enabled categories")
    func totalHonoursOptions() {
        let estimate = BackupSizeEstimate(base: 1_000, voiceNotes: 2_000, photos: 3_000, videos: 4_000)
        // Everything off — the default — is the baseline alone.
        #expect(estimate.total(with: BackupExportOptions()) == 1_000)
        #expect(estimate.total(with: BackupExportOptions(includeVoiceNotes: true)) == 3_000)
        #expect(estimate.total(with: BackupExportOptions(includePhotos: true)) == 4_000)
        #expect(estimate.total(with: BackupExportOptions(includeVideos: true)) == 5_000)
        #expect(
            estimate.total(with: BackupExportOptions(includeVoiceNotes: true, includePhotos: true))
                == 6_000
        )
        // All on matches the whole-archive `total`.
        let all = BackupExportOptions(includeVoiceNotes: true, includePhotos: true, includeVideos: true)
        #expect(estimate.total(with: all) == estimate.total)
    }

    @Test("formatted returns a non-empty, human-readable byte string")
    func formattedProducesString() {
        let estimate = BackupSizeEstimate(base: 5_000_000)
        // Locale-independent checks: a real string with a digit (the unit label varies
        // by device language, so we don't assert on "MB").
        #expect(!estimate.totalFormatted.isEmpty)
        #expect(estimate.totalFormatted.contains { $0.isNumber })
        // Zero still formats to a non-empty string.
        #expect(!estimate.formatted(0).isEmpty)
    }

    @Test("categories that are left at zero don't inflate the total")
    func partialCategories() {
        let photosOnly = BackupSizeEstimate(base: 500, photos: 9_500)
        #expect(photosOnly.total == 10_000)
        #expect(photosOnly.voiceNotes == 0)
        #expect(photosOnly.videos == 0)
    }
}
