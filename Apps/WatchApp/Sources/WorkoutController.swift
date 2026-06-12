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
        configuration.activityType = .underwaterDiving
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
    }

    func end() async {
        let end = Date()
        session?.end()
        try? await builder?.endCollection(at: end)
        _ = try? await builder?.finishWorkout()
        session = nil
        builder = nil
        isRunning = false
    }
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
    ) {}
}
