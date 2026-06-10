# CLAUDE_CODE_IMPLEMENTATION_GUIDE.md

## Goal

Build a production-quality SwiftUI application for Apple Watch Ultra and iPhone.

## Technology

- Swift 6
- SwiftUI
- SwiftData
- HealthKit
- CoreMotion
- CoreLocation
- WatchConnectivity

## Architecture

MVVM

Layers:
- Presentation
- Application
- Domain
- Infrastructure

## Repository Structure

Apps/
  WatchApp/
  iPhoneApp/

Packages/
  Domain/
  Persistence/
  Sensors/
  Sync/
  Strava/

## Implementation Order

Phase 1
- Project setup
- Models
- SwiftData

Phase 2
- Workout session
- Depth sensor
- Session manager

Phase 3
- Dive detection
- Haptics
- Event markers

Phase 4
- Watch UI

Phase 5
- Sync

Phase 6
- Charts and maps

Phase 7
- Strava

Phase 8
- Tests and polish

## Acceptance Criteria

A user can:
- Start a session
- Complete multiple dives
- Review session on phone
- Export to Strava

## Definition of Done

- Builds cleanly
- Unit tests pass
- Sync works
- No data loss during session
- Documentation updated
