import Foundation
import HealthKit
import Observation

/// Owns the `HKWorkoutSession` + `HKLiveWorkoutBuilder` for a single in-water
/// session. Background execution is kept alive by the workout session itself,
/// so no separate `WKExtendedRuntimeSession` is required.
///
/// Call order:
/// 1. `requestAuthorization()` — once per app launch (or each start is fine; HK de-dupes).
/// 2. `start()` — before sensors begin streaming.
/// 3. `end()` — after sensors have stopped; saves the `HKWorkout` to the Health app.
@MainActor
@Observable
final class WorkoutController: NSObject {
    private let healthStore = HKHealthStore()
    private var session: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?

    private(set) var isRunning = false

    /// Most recent heart rate (bpm) for the live readout; `nil` until the first sample.
    private(set) var currentHeartRate: Int?

    /// Called on the main actor with each heart-rate reading (bpm) so the
    /// coordinator can record it into the session's time series.
    @ObservationIgnored var onHeartRate: (@MainActor (Double) -> Void)?

    #if targetEnvironment(simulator)
    @ObservationIgnored private var syntheticHeartRateTask: Task<Void, Never>?
    #endif

    // MARK: - Authorisation

    func requestAuthorization() async throws {
        guard HKHealthStore.isHealthDataAvailable() else { return }

        let share: Set<HKSampleType> = [.workoutType()]

        var read: Set<HKObjectType> = [
            HKQuantityType(.heartRate),
            HKQuantityType(.activeEnergyBurned),
            HKQuantityType(.distanceSwimming),
        ]
        // Depth and water temperature are Watch Ultra-only types; guard availability.
        if #available(watchOS 9.0, *) {
            read.insert(HKQuantityType(.underwaterDepth))
            read.insert(HKQuantityType(.waterTemperature))
        }

        try await healthStore.requestAuthorization(toShare: share, read: read)
    }

    // MARK: - Session lifecycle

    func start() async throws {
        let configuration = HKWorkoutConfiguration()
        // .underwaterDiving is reserved for Apple's dive apps — HKWorkoutSession
        // rejects it for third parties (HKError 12, "does not support this
        // activity type"). Open-water swimming is the supported water type and
        // auto-engages Water Lock, which the underwater Crown/Action-button UX
        // depends on.
        configuration.activityType = .swimming
        configuration.swimmingLocationType = .openWater
        configuration.locationType = .outdoor

        let newSession = try HKWorkoutSession(healthStore: healthStore, configuration: configuration)
        let newBuilder = newSession.associatedWorkoutBuilder()
        newBuilder.dataSource = HKLiveWorkoutDataSource(
            healthStore: healthStore,
            workoutConfiguration: configuration
        )
        newSession.delegate = self
        newBuilder.delegate = self
        // Track the session *before* starting it, so a failure below can tear it
        // down. Otherwise a started-but-untracked session leaks and HealthKit
        // rejects the next start with "another workout session already started".
        session = newSession
        builder = newBuilder

        let start = Date()
        newSession.startActivity(with: start)
        do {
            try await newBuilder.beginCollection(at: start)
        } catch {
            newSession.end()
            session = nil
            builder = nil
            throw error
        }
        #if targetEnvironment(simulator)
        startSyntheticHeartRate()
        #endif
    }

    func end() async {
        let end = Date()
        #if targetEnvironment(simulator)
        syntheticHeartRateTask?.cancel()
        syntheticHeartRateTask = nil
        #endif
        session?.end()
        try? await builder?.endCollection(at: end)
        _ = try? await builder?.finishWorkout()
        session = nil
        builder = nil
        isRunning = false
        currentHeartRate = nil
    }

    #if targetEnvironment(simulator)
    /// The simulator has no HR sensor, so feed a gentle random-walk so the live
    /// readout and HR chart are testable there.
    private func startSyntheticHeartRate() {
        syntheticHeartRateTask?.cancel()
        syntheticHeartRateTask = Task { @MainActor [weak self] in
            var bpm = 72.0
            while !Task.isCancelled {
                bpm = min(120, max(45, bpm + Double.random(in: -4...4)))
                self?.currentHeartRate = Int(bpm.rounded())
                self?.onHeartRate?(bpm)
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
    #endif
}

// MARK: - HKWorkoutSessionDelegate

extension WorkoutController: HKWorkoutSessionDelegate {
    nonisolated func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didChangeTo toState: HKWorkoutSessionState,
        from fromState: HKWorkoutSessionState,
        date: Date
    ) {
        Task { @MainActor in
            switch toState {
            case .running:
                self.isRunning = true
            case .ended, .stopped, .paused:
                self.isRunning = false
            default:
                break
            }
        }
    }

    nonisolated func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didFailWithError error: Error
    ) {
        Task { @MainActor in
            self.isRunning = false
        }
    }
}

// MARK: - HKLiveWorkoutBuilderDelegate

extension WorkoutController: HKLiveWorkoutBuilderDelegate {
    nonisolated func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}

    nonisolated func workoutBuilder(
        _ workoutBuilder: HKLiveWorkoutBuilder,
        didCollectDataOf collectedTypes: Set<HKSampleType>
    ) {
        let hrType = HKQuantityType(.heartRate)
        guard collectedTypes.contains(hrType),
              let quantity = workoutBuilder.statistics(for: hrType)?.mostRecentQuantity() else { return }
        let bpm = quantity.doubleValue(for: HKUnit.count().unitDivided(by: HKUnit.minute()))
        Task { @MainActor in
            self.currentHeartRate = Int(bpm.rounded())
            self.onHeartRate?(bpm)
        }
    }
}
