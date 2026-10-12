# Depth profile boundaries

Depth charts use a zero baseline for surface intervals before, between and after
recorded dives. Single-dive profiles include zero boundaries too. These are
presentation points: historical sensor readings, statistics, backups and exports
retain their original data. Missing historical descent/ascent readings cannot be
recovered by drawing a boundary.

New recording uses timestamped surface crossings from Core Motion. Late events
are placed chronologically without rewinding the current live depth; the live
dive clock backfills a late descent prefix as well. Recording starts manually.

The detector, live session and haptic tracker share surface-rest confirmation.
An explicit surface reading ends a dive immediately. Otherwise a shallow ascent
keeps the dive open: each decrease in depth restarts the rest dwell. Only stable
shallow rest confirms an exit. Zero dwell skips the time delay but still requires
a steady shallow reading, rather than truncating an ongoing ascent. Dive
acceptance continues to use the deep run so shallow tails do not qualify spikes.

Tests cover slow and gentle ascents, zero dwell, descent noise, delayed surface
boundaries, manual dives and display-only surface baselines. UI verification
covers zoom presets, linked chart scrolling and hiding surface intervals.
