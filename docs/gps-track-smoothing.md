# Surface GPS distance

The Watch previously accumulated raw fix-to-fix distance live. Saved sessions
already used `DiveSession.surfaceDistanceMeters`, which respects the **Smooth GPS
track** setting. The session list's `7m` was seven minutes, not a second distance
estimate; it now uses an abbreviated duration such as `7 min`.

## Filtering

`TrackCleaner` now rejects invalid coordinates, invalid accuracy, duplicate
timestamps, extreme teleports, and smaller isolated motion spikes. Conservative
defaults are 4 m/s for swimming speed and 2 m/s² for acceleration, with allowances
for reported GPS uncertainty. These are tuning heuristics, not physiological or
safety limits. A point must disagree with its neighbours beyond the uncertainty;
sustained fast transit is retained rather than clipped to swimming speed.

Whole stationary recordings collapse to an accuracy-weighted centre, including
their noisy endpoints. At least five fixes and ten seconds of history are required.
Several time sections must show no resolvable progress, so returning to a pool
lap's starting point alone does not imply stationarity. Slow interior windows also
require stationary evidence in the original fixes before collapsing. The existing
constant-velocity smoother handles the remaining jitter. Longitude is unwrapped
across the date line.

CoreLocation's original measurement timestamps are preserved, including in batched
deliveries. Invalid fixes and cached fixes older than thirty seconds are discarded;
future timestamps have a five-second allowance. Session recording ignores duplicate
and out-of-order fixes and retains the existing two-second sampling interval.

## Consistency and compatibility

Live Watch distance uses the same cleaner as saved Watch and phone sessions. It is
recomputed when a retained fix arrives, and can revise earlier estimates as history
improves. With smoothing disabled, saved sessions explicitly say **Raw GPS distance**.
Stationary sessions can display **0 m** rather than hiding the distance row.

Raw coordinates remain stored. Existing sessions gain the improved filtering on
read without migration or a destructive rewrite. The phone's smoothing toggle
still controls both the map and its displayed distance.

GPS cannot reliably distinguish very short real movement from correlated drift
within its accuracy radius. This change is verified against synthetic fixtures;
it cannot establish the exact corrected distance of a particular pool session
without its raw track. Physical-device testing remains necessary for real-world
GPS quality and live Watch behaviour.

## Regression coverage

- Two-minute stationary scatter with over 50 m of raw accumulated distance.
- Slow sustained movement, normal swims, turns, and out-and-back pool laps.
- Isolated speed and acceleration spikes, noisy endpoints, and extreme teleports.
- Duplicate/invalid fixes, stale timestamps, delayed batches, and the date line.
- Live/saved distance equality, raw-data preservation, and the smoothing toggle.

Validation on 2026-10-04: 456 native Swift Testing tests across 50 suites passed,
including Domain, Persistence, Sensors, Session, Sync, and review-request tests.
The full iPhone simulator executable compiled and Watch app sources typechecked
with Swift 6. Normal Xcode/Tuist builds remain blocked by the unaccepted Xcode
licence; no signed binary or physical-device GPS validation is claimed.

Subsequent release verification: normal Xcode tests and both app builds passed
in GitHub Actions. The signed **1.4.0 (200)** build was uploaded and independently
verified as available in the existing internal TestFlight group on 2026-10-04.
Physical-device GPS validation remains pending.
