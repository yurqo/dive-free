import Testing
@testable import Domain

@Suite("diveTimeCue")
struct DiveTimeCueTests {
    @Test("a minor cue fires on each minor boundary")
    func minorBoundary() {
        #expect(diveTimeCue(elapsedSeconds: 10, minorInterval: 10, majorInterval: 60) == .minor)
        #expect(diveTimeCue(elapsedSeconds: 20, minorInterval: 10, majorInterval: 60) == .minor)
        #expect(diveTimeCue(elapsedSeconds: 50, minorInterval: 10, majorInterval: 60) == .minor)
    }

    @Test("a major cue fires on the major boundary and pre-empts the minor")
    func majorPrecedence() {
        #expect(diveTimeCue(elapsedSeconds: 60, minorInterval: 10, majorInterval: 60) == .major)
        #expect(diveTimeCue(elapsedSeconds: 120, minorInterval: 10, majorInterval: 60) == .major)
    }

    @Test("no cue off a boundary, and never at zero")
    func offBoundary() {
        #expect(diveTimeCue(elapsedSeconds: 11, minorInterval: 10, majorInterval: 60) == nil)
        #expect(diveTimeCue(elapsedSeconds: 7, minorInterval: 10, majorInterval: 60) == nil)
        #expect(diveTimeCue(elapsedSeconds: 0, minorInterval: 10, majorInterval: 60) == nil)
    }

    @Test("an interval of 0 disables that tier")
    func disabledTiers() {
        #expect(diveTimeCue(elapsedSeconds: 10, minorInterval: 0, majorInterval: 60) == nil)
        #expect(diveTimeCue(elapsedSeconds: 30, minorInterval: 10, majorInterval: 0) == .minor)
        #expect(diveTimeCue(elapsedSeconds: 60, minorInterval: 0, majorInterval: 0) == nil)
    }
}
