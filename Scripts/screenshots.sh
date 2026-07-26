#!/usr/bin/env bash
#
# screenshots.sh — capture App Store / marketing screenshots for DiveFree.
#
# TWO pipelines, one entry point, one output layout
# (`screenshots/<locale>/<device>/NN-slug.png`, which is what `stage_screenshots`
# in fastlane/Fastfile globs):
#
#   iOS   (iPhone + iPad, `--ios`)   — runs the standalone `ScreenshotTests`
#         UI-test target across every locale × device, applies a clean 9:41
#         status bar, and exports the captured PNG attachments.
#   watch (Apple Watch, `--watch`)   — installs the watch app on a watch
#         simulator and drives it with `simctl` alone: one launch per screen,
#         then `simctl io … screenshot`.
#
# Run both (the default), or just one: `Scripts/screenshots.sh --watch`.
#
# WHY the watch path is different rather than "the same test on watchOS":
# `XCTest.framework` is not part of the watchOS simulator SDK. There is no
# `XCUIApplication`, no UI automation, nothing to drive the app with — so the app
# drives itself: `--screenshot-screen <NN-slug>` makes it boot straight into one
# screen (see `WatchScreenshotMode`), and the script photographs the result. One
# process per screen, no navigation.
#
# Both apps launch with `--screenshot-demo`, which (DEBUG-only) boots a fresh
# in-memory store seeded with the same deterministic demo content (`DemoData`, in
# the Persistence package so both apps seed from one fixture set), so the output
# is reproducible and never touches real user data.
#
# Efficiency: the app is compiled ONCE per device with `build-for-testing`
# (producing an `.xctestrun`), then each locale reuses that build via
# `test-without-building`. That turns N locales × M devices *builds* into just M.
#
# Localization, and the trap that comes with the above: the command-line
# `-testLanguage` / `-testRegion` flags do NOT localize the app on the
# `test-without-building -xctestrun` path (the xctestrun's own, empty,
# `TestLanguage`/`TestRegion` values win), so every locale renders in the
# *simulator's* device language — which once shipped 80 wrong-language screenshots
# to App Store Connect. The language is therefore pinned explicitly in a per-locale
# copy of the `.xctestrun` (see `patch_xctestrun`): `TestLanguage`/`TestRegion` for
# the system furniture, and `SCREENSHOT_LANGUAGE`/`SCREENSHOT_LOCALE` for the test
# to turn into `-AppleLanguages`/`-AppleLocale` launch arguments, the way
# fastlane's own `snapshot` does it.
#
# On the WATCH path the language arrives the simple way — `simctl launch … app
# --screenshot-demo --screenshot-screen <slug> -AppleLanguages "(uk)" -AppleLocale
# uk_UA` — because there is no xctestrun in the way. Same mechanism the iOS test
# ends up using, one link shorter.
#
# Because a silent regression here is so expensive, the language is checked two
# ways — though the SECOND net differs by platform (see below):
#   1. DIRECTLY, and this is the one that matters — the app publishes its RESOLVED
#      localization (`Bundle.main.preferredLocalizations.first`, DEBUG +
#      `--screenshot-demo` only) and the run fails unless it matches what was
#      requested. On iOS the app publishes it as an accessibility identifier and
#      `ScreenshotTests` asserts on it; on the watch (no XCTest to assert from) the
#      app writes it to a file in its container and `verify_watch_language` reads it
#      back with `simctl get_app_container` — fail-closed: a missing or unreadable
#      file is a failure, and the file is deleted before every launch so a stale one
#      cannot vouch for the next locale. Either way a failed locale lands in
#      `failed` below, which forces `exit 1`. This is the PRIMARY net on both paths,
#      and on the watch it is the SOLE net for the `01-live` screen (see 2b).
#   2. Indirectly, as a backstop — a cross-locale md5 check. Kept, but never trusted
#      on its own: image diffs are defeated by rendering noise, and on the
#      wrong-language run a few jittering map-thumbnail pixels were enough to clear
#      every `en` pair. It comes in two flavours because the platforms differ:
#      2a. iOS — a WHOLE-image compare (`check_locales_differ`). The simulator clock
#          is pinned to 9:41 (`simctl status_bar override`), so the only per-locale
#          difference is the localized text; identical bytes ⇒ language not applied.
#      2b. watch — `simctl status_bar override` is REJECTED on watchOS, so the OS
#          clock is baked into every capture and no two watch PNGs are ever
#          byte-identical. A whole-image compare would therefore be vacuous. So the
#          watch backstop (`check_watch_locales_differ`) compares a status-bar-
#          CROPPED region instead, and skips `01-live` entirely (its dive clock
#          ticks every second, so even the crop is never stable) — that screen rests
#          on net 1 alone.
#
# Prerequisites:
#   - `tuist generate` has been run (DiveFree.xcworkspace + the ScreenshotTests /
#     DiveFreeWatch schemes exist).
#   - Xcode 16+ (for `xcrun xcresulttool export attachments`). See the export
#     step for the `xcparse` fallback if that subcommand is unavailable.
#
# This is a developer tool: readability and correctness over cleverness. It is
# idempotent — each locale/device output subdir is cleared just before it is
# (re-)written, so a partial failure leaves earlier good captures untouched (and a
# locale that fails leaves an EMPTY dir, never last run's PNGs). Output for device
# names no longer in `DEVICES`/`WATCH_DEVICES` is pruned up front — see
# `prune_stale_device_dirs`.

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration — edit these to taste.
# ---------------------------------------------------------------------------

WORKSPACE="DiveFree.xcworkspace"
SCHEME="ScreenshotTests"
# The watch app is built and installed directly (no test target — see the header).
WATCH_SCHEME="DiveFreeWatch"
WATCH_BUNDLE_ID="org.yurko.divefree.watchkitapp"

# Supported locales. Each maps to an Xcode -testLanguage / -testRegion pair via
# the helpers below. NOTE: this is the OUTPUT-folder key (what ASC expects), not
# necessarily the -testLanguage code — see `lang_for_locale` for the Portuguese
# case where the folder stays `pt-BR` but the app localizes to `pt`.
LOCALES=(en es fr it de pt-BR ja uk)

# Devices to capture on. Names must match `xcrun simctl list devicetypes`
# (and a matching simulator must exist — `xcrun simctl list devices`). Edit
# freely; a 6.9" iPhone and a 13" iPad cover the App Store required sizes.
DEVICES=(
    "iPhone 17 Pro Max"
    "iPad Pro 13-inch (M5)"
)

# Watch devices, kept separate from `DEVICES` because the pipeline is a different
# one (simctl install/launch, not xcodebuild + XCUITest) — but the OUTPUT is the
# same `screenshots/<locale>/<device>/` layout, so fastlane treats both alike.
#
# `Apple Watch Ultra 3 (49mm)` captures at 422×514, one of the two sizes deliver
# maps to App Store Connect's `APP_WATCH_ULTRA` display type (the other being the
# Ultra 2's 410×502) — and DiveFree targets the Ultra, so that is the right watch.
WATCH_DEVICES=(
    "Apple Watch Ultra 3 (49mm)"
)

# The watch screens to capture, as `NN-slug:dwell-seconds`. The slug is BOTH the
# `--screenshot-screen` argument and the output filename, and must match a case in
# `WatchScreenshotMode.Screen` (an unknown slug is a hard error there, not a
# fallback). Keep this list in step with that enum.
#
# The dwell is a POST-READY settle: capture waits for the app to confirm the screen
# rendered (see `wait_watch_ready`) and only then sleeps `dwell` before shooting —
# so this is no longer load-bearing for correctness, only for polish. `01-live`
# gets the longest one because the dwell is the dive clock advancing on screen: the
# app places its markers ~6 s in (when the marker becomes ready), then this settle
# carries the clock to a plausible mid-dive "0:2x" rather than a just-started
# "0:0x". The static screens only need a moment for charts to finish drawing.
WATCH_SCREENS=(
    "01-live:14"
    "02-summary:3"
    "03-profile:3"
    "04-sessions:3"
    "05-start:2"
)

# Screens EXCLUDED from the watch cross-locale byte check (see
# `check_watch_locales_differ`). `01-live` is a running session whose central dive
# clock ticks every second, so even a status-bar-cropped comparison can never be
# byte-stable across two captures — its language is covered by
# `verify_watch_language` alone. The four static screens ARE byte-checked.
WATCH_BYTE_EXCLUDE=("01-live")

# Pixels cropped off the TOP and BOTTOM of each watch capture before the
# cross-locale byte comparison, to drop the volatile OS clock (top) and page dots
# (bottom). 64 clears the ~55 px clock band with margin on the 514 px-tall Ultra;
# it only affects the comparison crop, never the shipped full-size PNG.
WATCH_CROP_STRIP_PX=64

# Which pipelines to run. Both by default; `--ios` / `--watch` narrow it.
RUN_IOS=1
RUN_WATCH=1

# Output roots (git-ignored — see .gitignore).
OUTPUT_ROOT="screenshots"
# Temporary result bundles / build products / logs land here; cleaned up on exit.
RESULT_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/divefree-screenshots.XXXXXX")"

# UDIDs of simulators THIS script booted (so the EXIT trap only shuts those
# down and leaves ones the user already had booted alone).
BOOTED_UDIDS=()

# ---------------------------------------------------------------------------
# Arguments.
# ---------------------------------------------------------------------------

usage() {
    cat <<'USAGE'
Usage: Scripts/screenshots.sh [--ios] [--watch]

  (no flags)  capture both the iOS (iPhone + iPad) and the Apple Watch sets
  --ios       capture only the iOS set (XCUITest-driven)
  --watch     capture only the Apple Watch set (simctl-driven)

Output: screenshots/<locale>/<device>/NN-slug.png
USAGE
}

# Narrowing flags are additive, so `--ios --watch` == the default.
if [ "$#" -gt 0 ]; then
    RUN_IOS=0
    RUN_WATCH=0
    for argument in "$@"; do
        case "$argument" in
            --ios)          RUN_IOS=1 ;;
            --watch)        RUN_WATCH=1 ;;
            -h|--help)      usage; exit 0 ;;
            *)              echo "Unknown argument: $argument" >&2; usage >&2; exit 2 ;;
        esac
    done
fi

# ---------------------------------------------------------------------------
# Cleanup.
# ---------------------------------------------------------------------------

# Shut down simulators we booted and remove the scratch dir. Runs on any exit
# (success, failure, or Ctrl-C) so we never leak booted sims or temp bundles.
cleanup() {
    local udid
    for udid in "${BOOTED_UDIDS[@]:-}"; do
        [ -n "$udid" ] || continue
        xcrun simctl shutdown "$udid" >/dev/null 2>&1 || true
    done
    [ -n "${RESULT_ROOT:-}" ] && rm -rf "$RESULT_ROOT"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Helpers.
# ---------------------------------------------------------------------------

# Map an OUTPUT locale key to the `-testLanguage` code Xcode should launch the
# app in. This must match a locale actually present in the app's
# Localizable.xcstrings (en, es, fr, it, de, pt, ja, uk) or the app silently
# falls back to English.
#   pt-BR -> pt : the app localizes to `pt` (there is no `pt-BR` variant), so we
#                 request `pt` while keeping the `pt-BR` output folder for ASC.
lang_for_locale() {
    case "$1" in
        pt-BR) echo "pt" ;;
        *)     echo "$1" ;;
    esac
}

# Map an OUTPUT locale key to the `-testRegion` (number/date formatting).
region_for_locale() {
    case "$1" in
        en)    echo "US" ;;
        es)    echo "ES" ;;
        fr)    echo "FR" ;;
        it)    echo "IT" ;;
        de)    echo "DE" ;;
        pt-BR) echo "BR" ;;
        ja)    echo "JP" ;;
        uk)    echo "UA" ;;
        *)     echo "US" ;;
    esac
}

# Resolve the UDID of the simulator for a device name, preferring the newest
# available runtime when several runtimes offer the same device name. Boots it
# if needed (the status-bar override requires a booted device). On failure prints
# an actionable error and returns non-zero.
#
# Prints TWO space-separated fields: "<udid> <booted-by-us|already-booted>".
# The second field exists because the caller must be the one to record the UDID
# in `BOOTED_UDIDS`: this function is invoked in a command substitution, i.e. a
# SUBSHELL, so anything it appends to the array dies with that subshell. That is
# exactly the bug that left both simulators running after every single run while
# `cleanup()` iterated an array that was permanently empty.
udid_for_device() {
    local device="$1"
    local udid
    # `xcrun simctl list devices available -j` groups devices by runtime; the
    # runtime identifiers (…iOS-18-2 etc.) sort so that the newest is last, so we
    # pick the match under the highest-sorting runtime.
    udid=$(xcrun simctl list devices available -j \
        | /usr/bin/python3 -c '
import json, sys
name = sys.argv[1]
data = json.load(sys.stdin)
best_runtime, best_udid = None, None
for runtime, devices in data["devices"].items():
    for d in devices:
        if d.get("name") == name and d.get("isAvailable", True):
            # Prefer the newest runtime (identifiers sort newest-last).
            if best_runtime is None or runtime > best_runtime:
                best_runtime, best_udid = runtime, d["udid"]
if best_udid:
    print(best_udid)
    sys.exit(0)
sys.exit(1)
' "$device") || {
        echo "  !! No available simulator named \"$device\"." >&2
        echo "     Create one, e.g.:" >&2
        echo "         xcrun simctl create \"$device\" \"$device\"" >&2
        echo "     Then re-run. See available names with:" >&2
        echo "         xcrun simctl list devicetypes" >&2
        echo "         xcrun simctl list devices available" >&2
        return 1
    }

    # Boot it if it is not already booted, and report which of the two happened
    # (so the EXIT trap only shuts down sims we started).
    local booted="already-booted"
    if ! xcrun simctl list devices -j \
        | /usr/bin/python3 -c '
import json, sys
udid = sys.argv[1]
data = json.load(sys.stdin)
for _, devices in data["devices"].items():
    for d in devices:
        if d["udid"] == udid and d.get("state") == "Booted":
            sys.exit(0)
sys.exit(1)
' "$udid"; then
        xcrun simctl boot "$udid" >/dev/null 2>&1 || true
        booted="booted-by-us"
    fi
    # Wait until fully booted so the status-bar override sticks.
    xcrun simctl bootstatus "$udid" -b >/dev/null 2>&1 || true

    echo "$udid $booted"
}

# Apply the canonical marketing status bar (9:41, full battery/signal).
apply_status_bar() {
    local udid="$1"
    xcrun simctl status_bar "$udid" override \
        --time "9:41" \
        --batteryState charged \
        --batteryLevel 100 \
        --cellularBars 4 \
        --wifiBars 3 >/dev/null 2>&1 || \
        echo "  !! status_bar override failed for $udid (continuing)" >&2
}

# Export PNG attachments from a result bundle into a directory.
# Uses Xcode 16+'s `xcresulttool export attachments`. If that subcommand is
# unavailable on your Xcode, install xcparse and swap the call below:
#     brew install chargepoint/xcparse/xcparse
#     xcparse screenshots "<xcresult>" "<dir>"
export_attachments() {
    local xcresult="$1"
    local dest="$2"
    mkdir -p "$dest"
    if xcrun xcresulttool export attachments \
        --path "$xcresult" \
        --output-path "$dest" >/dev/null 2>&1; then
        return 0
    fi
    echo "  !! 'xcresulttool export attachments' failed — is Xcode 16+ installed?" >&2
    echo "     Fallback: brew install chargepoint/xcparse/xcparse && \\" >&2
    echo "               xcparse screenshots \"$xcresult\" \"$dest\"" >&2
    return 1
}

# Delete `screenshots/<locale>/<device>` directories whose device is no longer
# configured, and report what was removed.
#
# WHY this is not cosmetic: renaming a device (as `DEVICES` above once did —
# `iPhone 16 Pro Max` -> `17 Pro Max`, `iPad Pro 13-inch (M4)` -> `(M5)`) leaves
# the old directories in
# place, and NOTHING downstream notices. `check_locales_differ` only iterates the
# configured devices, so it never inspects them — but the Fastfile's
# `stage_screenshots` globs *every* device dir under each locale and would upload
# both generations, i.e. yesterday's possibly-wrong-language set alongside
# today's, under one ASC locale.
#
# Only whole non-configured device dirs are touched, and only at the start of a
# run, so the "each locale/device subdir is cleared just before it is rewritten"
# resilience invariant still holds for everything we are actually capturing.
prune_stale_device_dirs() {
    local root="$1"
    shift
    local device_dir device_name keep pruned=0
    [ -d "$root" ] || return 0
    # Depth 2 = <locale>/<device>. `-print0`/`read -d ''` because both locale keys
    # and device names contain spaces and parentheses.
    while IFS= read -r -d '' device_dir; do
        device_name="$(/usr/bin/basename "$device_dir")"
        keep=0
        for configured in "$@"; do
            [ "$device_name" = "$configured" ] && { keep=1; break; }
        done
        [ "$keep" -eq 1 ] && continue
        echo "    pruning stale device dir: $device_dir"
        rm -rf "$device_dir"
        pruned=$((pruned + 1))
    done < <(/usr/bin/find "$root" -mindepth 2 -maxdepth 2 -type d -print0)
    [ "$pruned" -gt 0 ] && echo "    pruned $pruned stale device dir(s) not in DEVICES/WATCH_DEVICES"
    return 0
}

# Empty every `<locale>/<device>` output dir for one device, up front.
#
# WHY up front and not just per-locale: the per-locale `rm -rf "$dest"` inside the
# capture loop only protects locales the loop reaches. All three DEVICE-level
# bailouts (`udid_for_device` failing, `build-for-testing` failing, no `.xctestrun`
# produced) `continue` before that loop runs even once, so without this the device
# keeps the PREVIOUS run's PNGs for all 8 locales. Those are the dangerous ones:
# `prune_stale_device_dirs` won't touch them (the device IS configured), the
# sanity check hashes them as if fresh, and `fastlane ios metadata` reads the
# folder rather than our exit code — so a later lane run happily uploads
# yesterday's, possibly wrong-language, set for a device that captured nothing
# today. Clearing here makes the header's invariant true for devices as well as
# locales: a combination that fails leaves an EMPTY dir, never stale PNGs.
clear_device_output() {
    local root="$1" device="$2"
    shift 2
    local locale
    for locale in "$@"; do
        rm -rf "$root/$locale/$device"
    done
}

# Locate the `.xctestrun` file produced by `build-for-testing` under a
# derived-data path. Prints its path; returns non-zero if none is found.
find_xctestrun() {
    local derived="$1"
    local found
    found=$(/usr/bin/find "$derived/Build/Products" -maxdepth 1 -name "*.xctestrun" 2>/dev/null | head -n 1)
    [ -n "$found" ] || return 1
    echo "$found"
}

# Write a per-locale copy of an `.xctestrun` with the language/locale pinned on
# every test target, and print the copy's path.
#
# This is the workaround for `-testLanguage`/`-testRegion` being ignored by
# `test-without-building` (see the header). THREE channels are written, because
# each covers a different part of the problem:
#   - TestLanguage / TestRegion — the supported, documented channel, and almost
#     certainly why the CLI flags looked like they did nothing: the xctestrun
#     this scheme produces (FormatVersion 1) ships `TestLanguage: ""` /
#     `TestRegion: ""`, and the file's empty values win over the command line.
#     Setting them here is what localizes system-rendered chrome (keyboard,
#     system alerts, share sheet, date pickers) — without it, that furniture
#     stayed in the simulator's own language in all 8 sets.
#   - EnvironmentVariables (the runner's env) — SCREENSHOT_LANGUAGE /
#     SCREENSHOT_LOCALE. `ScreenshotTests.setUpWithError()` reads them, appends
#     `-AppleLanguages`/`-AppleLocale` to the app's launch arguments, and — the
#     important part — asserts the app's RESOLVED localization matches
#     SCREENSHOT_LANGUAGE, so a broken override fails the run instead of quietly
#     producing a wrong-language set.
#   - UITargetAppCommandLineArguments — belt and braces: xcodebuild passes these
#     straight to the app under test, so the override also lands when the runner
#     launches the app without going through our `setUpWithError` (and it keeps
#     working if the env channel is ever refactored away).
# Existing environment variables are merged, never clobbered — the xctestrun
# ships DYLD_*/`__XCODE_BUILT_PRODUCTS_DIR_PATHS` entries the run needs.
#
# Handles both on-disk layouts: v2+ nests targets under
# `TestConfigurations[].TestTargets[]`; v1 keeps one dict per target at the top
# level. We walk for target dicts rather than assuming a version.
patch_xctestrun() {
    local src="$1" dest="$2" lang="$3" locale="$4" region="$5"
    /usr/bin/python3 -c '
import plistlib, sys

src, dest, lang, locale, region = sys.argv[1:6]

with open(src, "rb") as handle:
    plist = plistlib.load(handle)

def test_targets(plist):
    """Yield every test-target dict, whichever xctestrun layout this is."""
    configurations = plist.get("TestConfigurations")
    if isinstance(configurations, list):          # v2+
        for configuration in configurations:
            for target in configuration.get("TestTargets") or []:
                if isinstance(target, dict):
                    yield target
        return
    for key, value in plist.items():              # v1 (legacy)
        # Skip the "__xctestrun_metadata__" bookkeeping entry and anything that
        # is not a target dict.
        if key.startswith("__") or not isinstance(value, dict):
            continue
        if "TestBundlePath" in value or "TestHostPath" in value:
            yield value

patched = 0
for target in test_targets(plist):
    # The supported channel — and the one whose EMPTY default was beating the
    # `-testLanguage`/`-testRegion` command-line flags.
    target["TestLanguage"] = lang
    target["TestRegion"] = region
    environment = target.get("EnvironmentVariables")
    if not isinstance(environment, dict):
        environment = {}
    environment["SCREENSHOT_LANGUAGE"] = lang
    environment["SCREENSHOT_LOCALE"] = locale
    target["EnvironmentVariables"] = environment
    # Appended, not assigned, for the same reason as above: the scheme may
    # already pass arguments to the app under test.
    arguments = target.get("UITargetAppCommandLineArguments")
    if not isinstance(arguments, list):
        arguments = []
    target["UITargetAppCommandLineArguments"] = arguments + [
        "-AppleLanguages", "(%s)" % lang,
        "-AppleLocale", locale,
    ]
    patched += 1

if not patched:
    sys.exit("no test-target dicts found in %s" % src)

with open(dest, "wb") as handle:
    plistlib.dump(plist, handle)
' "$src" "$dest" "$lang" "$locale" "$region"
}

# ---------------------------------------------------------------------------
# Watch capture (simctl only — there is no XCTest on watchOS; see the header).
# ---------------------------------------------------------------------------

# Print the path of the watch `.app` built under a derived-data path.
find_watch_app() {
    local derived="$1"
    local found
    found=$(/usr/bin/find "$derived/Build/Products" -maxdepth 2 -type d -name "*.app" 2>/dev/null | head -n 1)
    [ -n "$found" ] || return 1
    echo "$found"
}

# Print the path of the file the watch app writes its RESOLVED localization into
# (see `WatchScreenshotMode.publishResolvedLanguage`). Fails if the app has never
# been installed/launched on this simulator (no data container yet).
watch_language_file() {
    local udid="$1"
    local container
    container=$(xcrun simctl get_app_container "$udid" "$WATCH_BUNDLE_ID" data 2>/dev/null) || return 1
    [ -n "$container" ] || return 1
    echo "$container/Documents/screenshot-language.txt"
}

# Delete the resolved-language file, so the next launch either rewrites it or the
# verification below fails. Without this a file left by the PREVIOUS locale could
# be read as if it described this one.
clear_watch_language() {
    local file
    file=$(watch_language_file "$1") || return 0
    rm -f "$file"
}

# Path of the "screen ready" marker the app writes once the intended screen has
# actually rendered with its data (see `WatchScreenshotMode.publishScreenReady`).
watch_ready_file() {
    local udid="$1"
    local container
    container=$(xcrun simctl get_app_container "$udid" "$WATCH_BUNDLE_ID" data 2>/dev/null) || return 1
    [ -n "$container" ] || return 1
    echo "$container/Documents/screenshot-ready.txt"
}

# Remove the ready marker before a launch, so a marker left by the PREVIOUS
# capture can never be mistaken for this one having rendered.
clear_watch_ready() {
    local file
    file=$(watch_ready_file "$1") || return 0
    rm -f "$file"
}

# Poll until the app announces the EXPECTED screen is rendered and populated, or
# fail after `timeout` seconds. This is the fail-closed replacement for a blind
# `sleep`: a screen that stalls, throws on start, or renders the wrong view never
# writes its marker (or writes a different slug), so we time out and fail the
# capture instead of photographing whatever happened to be on screen. Matching the
# slug also catches a screen that rendered the wrong content under the right name.
wait_watch_ready() {
    local udid="$1" screen="$2" timeout="${3:-40}"
    local file waited=0 got
    file=$(watch_ready_file "$udid") || {
        echo "       !! could not resolve the app data container — cannot confirm the screen rendered" >&2
        return 1
    }
    while [ "$waited" -lt "$timeout" ]; do
        if [ -s "$file" ]; then
            got=$(/usr/bin/tr -d '[:space:]' < "$file")
            [ "$got" = "$screen" ] && return 0
        fi
        sleep 1
        waited=$((waited + 1))
    done
    echo "       !! $screen never signalled ready within ${timeout}s (marker: $(cat "$file" 2>/dev/null || echo none))." >&2
    echo "          Refusing to capture: the app did not confirm the intended screen rendered" >&2
    echo "          with its data (a start failure, a stall, or a wrong/renamed slug)." >&2
    return 1
}

# Fail unless a PNG is RGB with no alpha channel. Every screenshot App Store
# Connect has accepted is RGB; an RGBA image is rejected server-side, and because
# the upload runs `overwrite_screenshots: true` a rejection can leave the listing
# with the old set deleted and the new one failed. We capture with `--mask=black`
# (which flattens the rounded-corner mask to opaque black, yielding RGB), and this
# asserts that actually happened rather than trusting the flag. Reads the PNG IHDR
# colour-type byte directly — no image library — where 2/0 are alpha-free
# (truecolour / greyscale) and 4/6 carry alpha; a `tRNS` chunk anywhere also
# counts as alpha.
assert_no_alpha() {
    local png="$1"
    /usr/bin/python3 - "$png" <<'PY'
import sys, struct
path = sys.argv[1]
with open(path, "rb") as handle:
    data = handle.read()
if data[:8] != b"\x89PNG\r\n\x1a\n":
    sys.exit("not a PNG: %s" % path)
# IHDR is the first chunk: 8-byte signature, 4-byte length, "IHDR", then
# width(4) height(4) bitdepth(1) colortype(1)…
color_type = data[25]
if color_type in (4, 6):
    sys.exit("%s has an alpha channel (PNG colour type %d)" % (path, color_type))
# A palette or truecolour image can still carry transparency via a tRNS chunk.
if b"tRNS" in data:
    sys.exit("%s carries a tRNS transparency chunk" % path)
PY
}

# THE check for the watch path: fail unless the app resolved the language we asked
# for. Fail-closed — an unreadable container, a missing file, or an empty file all
# count as failures, because "we could not tell" must never read as "it is fine".
#
# This is the watch's stand-in for `ScreenshotTests.assertRequestedLanguageApplied`
# (no XCTest on watchOS to assert from) and it exists for the same reason: a
# language override that silently does nothing produces a full set of
# perfectly-valid-looking screenshots in the wrong language — which has shipped to
# App Store Connect before. Only the app knows what it resolved, so it writes it
# down and we compare.
#
# Compared on the LANGUAGE SUBTAG so a `pt` request still matches a `pt-BR`
# resolution (the `pt-BR` output folder asks the app for plain `pt`).
verify_watch_language() {
    local udid="$1" requested="$2"
    local file resolved
    file=$(watch_language_file "$udid") || {
        echo "       !! could not resolve the app data container — cannot verify the language" >&2
        return 1
    }
    if [ ! -s "$file" ]; then
        echo "       !! the app published no resolved language ($file missing or empty)." >&2
        echo "          Refusing to capture unverified screenshots: either the app was not" >&2
        echo "          launched with --screenshot-demo, or this is not a DEBUG build, or" >&2
        echo "          WatchScreenshotMode.publishResolvedLanguage() was removed." >&2
        return 1
    fi
    resolved=$(/usr/bin/tr -d '[:space:]' < "$file")
    if [ "$(echo "${resolved%%-*}" | /usr/bin/tr '[:upper:]' '[:lower:]')" \
         != "$(echo "${requested%%-*}" | /usr/bin/tr '[:upper:]' '[:lower:]')" ]; then
        echo "       !! Language override NOT applied: requested \"$requested\" but the app" >&2
        echo "          resolved \"$resolved\". These screenshots would be in the wrong" >&2
        echo "          language — check that the -AppleLanguages/-AppleLocale launch" >&2
        echo "          arguments still reach the app and that \"$requested\" exists in" >&2
        echo "          Localizable.xcstrings." >&2
        return 1
    fi
    return 0
}

# Launch one screen, wait for it to CONFIRM it rendered, verify the language,
# photograph it as RGB. Prints its own progress; returns non-zero if anything went
# wrong (the caller counts that as a failed combination, which forces `exit 1`).
capture_watch_screen() {
    local udid="$1" screen="$2" dwell="$3" lang="$4" app_locale="$5" dest="$6"

    # Start from a clean slate: kill any previous instance and give the OS a moment
    # to tear it down. On a first install→terminate→launch, launching too soon
    # returned a PID for a process that came up with NO launch arguments applied
    # (English Start screen, no probe) — the settle plus --terminate-running-process
    # below close that race.
    xcrun simctl terminate "$udid" "$WATCH_BUNDLE_ID" >/dev/null 2>&1 || true
    sleep 1
    # Drop both markers so neither a previous locale's language probe nor a previous
    # screen's ready marker can vouch for this launch.
    clear_watch_language "$udid"
    clear_watch_ready "$udid"

    # The launch arguments are the whole mechanism: `--screenshot-demo` +
    # `--screenshot-screen` pick the seeded store and the screen (see
    # `WatchScreenshotMode`), `-AppleLanguages`/`-AppleLocale` land in the app's
    # NSArgumentDomain and localize it — the same override fastlane's `snapshot`
    # uses, and the same one the iOS test applies. `--terminate-running-process`
    # guarantees a fresh process even if the terminate above has not fully landed.
    #
    # ARGUMENT ORDER IS LORE, NOT STYLE: the `-Apple…` pair must come FIRST. With
    # `--screenshot-demo` immediately after the bundle id, `simctl` treats it as one
    # of ITS OWN options, swallows it, and forwards NOTHING that follows — the app
    # then launches with no demo store and no language override, and prints a PID as
    # if all was well. That is a wrong-language screenshot with a zero exit code, so
    # the single-dash arguments lead and the double-dash ones trail.
    if ! xcrun simctl launch --terminate-running-process "$udid" "$WATCH_BUNDLE_ID" \
        -AppleLanguages "($lang)" -AppleLocale "$app_locale" \
        --screenshot-demo --screenshot-screen "$screen" >/dev/null 2>&1; then
        echo "       !! simctl launch failed for $screen" >&2
        return 1
    fi

    # Fail closed: wait for the app to confirm THIS screen rendered with its data,
    # rather than blindly sleeping and photographing whatever is up.
    wait_watch_ready "$udid" "$screen" || return 1

    # Post-ready settle. For `01-live` this is also the dive clock advancing to a
    # plausible mid-dive value; for the static screens it lets charts finish drawing.
    sleep "$dwell"

    verify_watch_language "$udid" "$lang" || return 1

    # `--mask=black` yields an RGB (alpha-free) PNG; `assert_no_alpha` proves it.
    if ! xcrun simctl io "$udid" screenshot --mask=black "$dest/$screen.png" >/dev/null 2>&1; then
        echo "       !! simctl io screenshot failed for $screen" >&2
        return 1
    fi
    if ! assert_no_alpha "$dest/$screen.png"; then
        echo "       !! $screen.png is not alpha-free — App Store Connect would reject it" >&2
        return 1
    fi
    xcrun simctl terminate "$udid" "$WATCH_BUNDLE_ID" >/dev/null 2>&1 || true
    return 0
}

# SECONDARY net: fail the run if two locales produced byte-identical screenshots
# of the same screen.
#
# The PRIMARY guarantee is elsewhere — the app publishes its resolved localization
# and the run fails on a mismatch (`assertRequestedLanguageApplied` on iOS,
# `verify_watch_language` here). This image check exists only to catch what that
# cannot: a bug where the language applies to the app but the *captures* still come
# from a stale/shared source. It matters MORE on the watch, not less: that path has
# no XCUITest probe, so these two checks are all it has.
#
# Screenshots are compared per device and per *logical* screen, keyed by an
# "NN-slug". Where that slug comes from depends on the pipeline:
#   - iOS: from the device dir's manifest.json (`suggestedHumanReadableName`,
#     normalized exactly like the Fastfile's `readable_name_for`), because
#     `xcresulttool` exports the attachments under random UUID filenames.
#   - watch: from the filename itself — `simctl io … screenshot` writes wherever we
#     say, so the captures are already named `01-live.png` and carry no manifest.
#
# THE RULE: flag ANY single slug that is byte-identical across two locales, unless
# that slug is in LOCALE_INVARIANT (currently empty — every screen we capture
# shows a localized tab bar and nav title, so none of them may legitimately match
# across languages).
#
# WHY not the previous rule: it flagged a pair only when EVERY shared slug
# matched. That is unanimity, so a single noisy image acquits the whole pair — and
# it did. Measured on the archived output of the wrong-language run, on the iPhone
# set every `en`-vs-other-locale pair had exactly 2 of 5 slugs byte-identical
# (map-thumbnail jitter accounts for the rest), so the old rule cleared all 7 of
# them while they were in fact all the same language; the per-slug rule flags
# every one. One differing image no longer excuses the identical ones next to it,
# and the allowlist — not a tolerance — is the escape hatch if a
# genuinely text-free screen is ever added (an allowlist has to be *chosen*, so it
# can be reviewed; a tolerance silently absorbs whatever fits under it).
#
# Every input problem is also fatal — a locale/device dir that is missing, empty,
# unmapped, partially mapped, or ambiguous, and a run where fewer than two locales
# ended up comparable. A check that quietly compares nothing and prints "passed" is
# worse than no check, so "I could not conclude" is reported as failure, never as
# success (the summary line states how many comparisons were made).
#
# Usage: check_locales_differ <root> <locale>… -- <device>…
check_locales_differ() {
    /usr/bin/python3 -c '
import hashlib, json, os, re, sys

root = sys.argv[1]
rest = sys.argv[2:]
separator = rest.index("--")
locales, devices = rest[:separator], rest[separator + 1:]

# Slugs that may legitimately be byte-identical across languages (a screen with
# no localized text anywhere). Empty on purpose — see the rule above. Add with a
# comment naming the screen and why it carries no localized pixels.
LOCALE_INVARIANT = set()

class Unusable(Exception):
    """A device dir we cannot draw a conclusion from — always fatal."""

# A capture that already carries its screen name, e.g. "01-live.png" — how the
# watch pipeline writes its files (`simctl io … screenshot` writes to a path we
# choose, so there is nothing to look up). Deliberately excludes "_": the iOS
# exports are named like "01-dives_1_<UUID>.png", and those must NOT slip through as
# self-describing (their UUID makes every cross-locale key unique, which is exactly
# the silent all-pass this guard exists to prevent).
SELF_NAMED = re.compile(r"\A\d{2,}-[0-9A-Za-z][0-9A-Za-z.-]*\Z")

# A bare UUID stem, e.g. "12345678-9abc-def0-1234-56789abcdef0" — what the xcparse
# fallback would name an iOS export with no manifest. ~2.3% of UUIDs have an
# all-digit first group, which `SELF_NAMED` (leading `\d{2,}-`) would otherwise
# accept as self-named — reopening the very silent all-pass this guard exists to
# stop. Rejected explicitly so a watch dir and a manifest-less iOS dir never look
# alike. A real watch slug cannot collide: its `NN-` prefix is two digits, never
# the eight-hex first group of a UUID.
HEX_UUID = re.compile(r"\A[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}\Z")

def slug_hashes(device_dir):
    """{"03-trips": "<md5>"} for one <locale>/<device> directory.

    Two ways a PNG gets its slug: the manifest (iOS — see below), or its own
    filename when that is already `NN-slug.png` (watch, see `SELF_NAMED`).

    Every way this can fail to produce a full, keyed set raises Unusable. Nothing
    here is best-effort ON PURPOSE: anything less than "every PNG mapped to a
    distinct slug" means the loop below compares fewer screens than it appears to,
    and a check that silently compares nothing prints "passed" — the exact shape of
    the failure that shipped 80 wrong-language screenshots. The ways out:

      - no PNGs at all: the locale/device produced nothing (a failed or skipped
        combination), so there is nothing to conclude and it must not read as a
        clean bill of health for that locale;
      - PNGs but nothing mapped: no/unreadable manifest.json AND not self-named, so
        keys would fall back to the exported random-UUID filenames, which never
        match across locales — every comparison then trivially "passes". The
        `xcparse` fallback documented in the header produces precisely that state;
      - PNGs only PARTIALLY mapped: a manifest that names 1 of 5 attachments would
        quietly leave 4 screens uncompared (this is what a future `xcresulttool`
        that nests or renames exports would look like);
      - two PNGs on one slug: the second overwrites the first, so a screen we
        believe we compared was never compared.
    """
    pngs = sorted(entry for entry in os.listdir(device_dir)
                  if entry.lower().endswith(".png"))
    if not pngs:
        raise Unusable("%s: no PNGs — nothing to compare for this locale" % device_dir)

    names = {}
    manifest = os.path.join(device_dir, "manifest.json")
    if os.path.exists(manifest):
        try:
            with open(manifest) as handle:
                data = json.load(handle)
        except ValueError:
            data = []
        groups = data if isinstance(data, list) else [data]
        for group in groups:
            for attachment in group.get("attachments") or []:
                exported = attachment.get("exportedFileName")
                human = attachment.get("suggestedHumanReadableName") or ""
                if not exported or not human:
                    continue
                # "01-dives_0_UUID.png" -> "01-dives"
                slug = re.sub(r"_\d+_[0-9A-Fa-f-]+\.png\Z", "", human)
                names[exported] = os.path.splitext(slug)[0]

    # Captures that name themselves (the watch pipeline), unless the name is
    # actually a bare UUID masquerading as a slug (see HEX_UUID).
    for entry in pngs:
        if entry in names:
            continue
        stem = os.path.splitext(entry)[0]
        if SELF_NAMED.match(stem) and not HEX_UUID.match(stem):
            names[entry] = stem

    unmapped = [entry for entry in pngs if entry not in names]
    if len(unmapped) == len(pngs):
        raise Unusable(
            "%s: %d PNG(s) but no usable slug map — no manifest.json, and the "
            "filenames are not NN-slug.png either" % (device_dir, len(pngs))
        )
    if unmapped:
        raise Unusable(
            "%s: %d of %d PNG(s) unmapped (%s) — they would be silently left out "
            "of the comparison"
            % (device_dir, len(unmapped), len(pngs), ", ".join(unmapped))
        )

    hashes = {}
    for entry in pngs:
        slug = names[entry]
        with open(os.path.join(device_dir, entry), "rb") as handle:
            digest = hashlib.md5(handle.read()).hexdigest()
        if slug in hashes:
            raise Unusable(
                "%s: two screenshots map to the same slug %r — the names "
                "cannot be trusted to identify screens" % (device_dir, slug)
            )
        hashes[slug] = digest
    return hashes

problems = []
# Number of slug comparisons actually performed. Counted so that "nothing was
# comparable" can never be reported as a pass — see the tail of this script.
compared = 0
for device in devices:
    per_locale = {}
    for locale in locales:
        device_dir = os.path.join(root, locale, device)
        # A missing dir is a problem, not a skip: every configured locale/device is
        # attempted, and each gets its dir created before the run, so an absent one
        # means the combination never completed.
        if not os.path.isdir(device_dir):
            problems.append(
                "    !! %s: no output directory — that locale/device did not "
                "complete, so its screenshots were never verified" % device_dir
            )
            continue
        try:
            per_locale[locale] = slug_hashes(device_dir)
        except Unusable as error:
            problems.append("    !! %s" % error)

    present = [locale for locale in locales if per_locale.get(locale)]
    if len(present) < 2:
        problems.append(
            "    !! %s: only %d locale(s) comparable — this check concluded "
            "nothing for this device" % (device, len(present))
        )
    for i, left in enumerate(present):
        for right in present[i + 1:]:
            shared = set(per_locale[left]) & set(per_locale[right])
            compared += len(shared)
            identical = sorted(
                slug for slug in shared
                if slug not in LOCALE_INVARIANT
                and per_locale[left][slug] == per_locale[right][slug]
            )
            if identical:
                problems.append(
                    "    !! %s: locales %s and %s produced byte-identical "
                    "screenshots of %s — the language override is not being "
                    "applied to those screens."
                    % (device, left, right, ", ".join(identical))
                )

if not compared:
    # Belt and braces on top of the per-directory errors above: whatever new way
    # the inputs go wrong, an empty comparison must never print "passed".
    problems.append(
        "    !! nothing was compared at all — the check reached no conclusion"
    )

if problems:
    print("==> Cross-locale sanity check FAILED", file=sys.stderr)
    for problem in problems:
        print(problem, file=sys.stderr)
    print("", file=sys.stderr)
    print("    Do NOT upload these.", file=sys.stderr)
    print("    iOS: `-testLanguage`/`-testRegion` on the command line do NOT localize", file=sys.stderr)
    print("    the app on the `test-without-building -xctestrun` path; the language", file=sys.stderr)
    print("    must arrive via the patched xctestrun (TestLanguage/TestRegion +", file=sys.stderr)
    print("    SCREENSHOT_LANGUAGE / SCREENSHOT_LOCALE -> -AppleLanguages/-AppleLocale", file=sys.stderr)
    print("    in ScreenshotTests.setUpWithError).", file=sys.stderr)
    print("    watch: the language arrives as -AppleLanguages/-AppleLocale launch", file=sys.stderr)
    print("    arguments on `simctl launch` (see capture_watch_screen).", file=sys.stderr)
    print("    Check that all of it is still wired.", file=sys.stderr)
    sys.exit(1)

print("==> Cross-locale sanity check passed (%d screen comparisons, none identical "
      "across locales)" % compared)
' "$@"
}

# The watch equivalent of `check_locales_differ`, for ONE watch device — but on a
# CROP of each capture rather than the whole PNG.
#
# WHY it cannot be the whole PNG: watchOS draws its own clock into every
# screenshot and `simctl status_bar override` is rejected on watchOS (unlike iOS,
# where the clock is pinned to 9:41), so the wall clock changes minute to minute
# and no two watch captures are ever byte-identical. A whole-image comparison
# therefore can NEVER fire — it would "pass" without ever detecting a
# language-not-applied set, the exact vacuous check this guards against. Cropping
# the volatile top/bottom bands (the clock, and the page-indicator dots) away
# leaves a deterministic, localized middle: if two locales rendered the SAME
# language their crops are byte-identical and this fires.
#
# `01-live` is deliberately NOT byte-checked here (it is passed in the exclude
# list): it is a running session whose central dive clock ticks every second, so
# even its crop differs between two captures of the same locale. Its language is
# covered by `verify_watch_language` alone — the primary, fail-closed net that all
# five screens rely on regardless.
#
# Usage: check_watch_locales_differ <root> <device> <strip_px> <locale>… -- <slug>…
check_watch_locales_differ() {
    /usr/bin/python3 -c '
import hashlib, os, struct, subprocess, sys, tempfile

root, device, strip = sys.argv[1], sys.argv[2], int(sys.argv[3])
rest = sys.argv[4:]
separator = rest.index("--")
locales, slugs = rest[:separator], rest[separator + 1:]

def png_size(path):
    with open(path, "rb") as handle:
        head = handle.read(24)
    if head[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError("%s is not a PNG" % path)
    width, height = struct.unpack(">II", head[16:24])
    return width, height

def cropped_digest(path, tmpdir):
    """md5 of `path` with `strip` px removed from top AND bottom.

    sips centred crop only (its --cropOffset is a no-op on this toolchain), so
    cropping to height-2*strip drops the clock at the top and the page dots at the
    bottom symmetrically — both volatile — while keeping the localized middle.
    """
    width, height = png_size(path)
    crop_h = max(1, height - 2 * strip)
    out = os.path.join(tmpdir, "crop.png")
    subprocess.run(
        ["sips", "-c", str(crop_h), str(width), path, "--out", out],
        check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    with open(out, "rb") as handle:
        return hashlib.md5(handle.read()).hexdigest()

problems = []
compared = 0
with tempfile.TemporaryDirectory() as tmpdir:
    for slug in slugs:
        per_locale = {}
        for locale in locales:
            path = os.path.join(root, locale, device, slug + ".png")
            if not os.path.isfile(path):
                problems.append(
                    "    !! %s: missing for locale %s — that capture did not "
                    "complete, so it was never verified" % (path, locale)
                )
                continue
            try:
                per_locale[locale] = cropped_digest(path, tmpdir)
            except Exception as error:  # noqa: BLE001 — any failure is fatal here
                problems.append("    !! %s: could not crop/hash — %s" % (path, error))

        present = [locale for locale in locales if locale in per_locale]
        if len(present) < 2:
            problems.append(
                "    !! %s %s: only %d locale(s) comparable — concluded nothing"
                % (device, slug, len(present))
            )
        for i, left in enumerate(present):
            for right in present[i + 1:]:
                compared += 1
                if per_locale[left] == per_locale[right]:
                    problems.append(
                        "    !! %s: locales %s and %s produced byte-identical %s "
                        "(status-bar cropped) — the language override is not being "
                        "applied to that screen." % (device, left, right, slug)
                    )

if not compared:
    problems.append("    !! nothing was compared at all — the check reached no conclusion")

if problems:
    print("==> Watch cross-locale sanity check FAILED", file=sys.stderr)
    for problem in problems:
        print(problem, file=sys.stderr)
    print("", file=sys.stderr)
    print("    Do NOT upload these. The watch language arrives as", file=sys.stderr)
    print("    -AppleLanguages/-AppleLocale launch arguments on `simctl launch`", file=sys.stderr)
    print("    (see capture_watch_screen); verify_watch_language is the primary net.", file=sys.stderr)
    sys.exit(1)

print("==> Watch cross-locale sanity check passed (%d cropped comparisons across %s, "
      "none identical)" % (compared, device))
' "$@"
}

# ---------------------------------------------------------------------------
# Main.
# ---------------------------------------------------------------------------

# Every device the two pipelines are configured for. Used for pruning and for the
# cross-locale check, both of which must see the WATCH dirs too — a device dir
# missing from this list is one fastlane still uploads but nothing verifies.
ALL_DEVICES=("${DEVICES[@]}" "${WATCH_DEVICES[@]}")

echo "==> Screenshot capture"
echo "    workspace : $WORKSPACE"
echo "    pipelines : $([ "$RUN_IOS" -eq 1 ] && printf 'iOS ')$([ "$RUN_WATCH" -eq 1 ] && printf 'watch')"
echo "    locales   : ${LOCALES[*]}"
[ "$RUN_IOS" -eq 1 ]   && echo "    devices   : ${DEVICES[*]} (scheme $SCHEME)"
[ "$RUN_WATCH" -eq 1 ] && echo "    watch     : ${WATCH_DEVICES[*]} (scheme $WATCH_SCHEME)"
echo "    results   : $RESULT_ROOT"
echo

mkdir -p "$OUTPUT_ROOT"

# Drop output from device names we no longer capture (see the function comment:
# fastlane would otherwise upload both generations). Pruned against BOTH device
# lists regardless of which pipeline is running, so `--watch` can't delete the
# iPhone set (or the other way round).
prune_stale_device_dirs "$OUTPUT_ROOT" "${ALL_DEVICES[@]}"

captured=0
failed=0

for device in "${DEVICES[@]}"; do
    [ "$RUN_IOS" -eq 1 ] || break
    echo "==> Device: $device"

    # Drop this device's previous output the moment it is in play — BEFORE the
    # three bailouts below, each of which skips the locale loop (and its
    # per-locale clear) entirely. See `clear_device_output`.
    clear_device_output "$OUTPUT_ROOT" "$device" "${LOCALES[@]}"

    # "<udid> <booted-by-us|already-booted>" — the boot flag has to come back
    # through stdout and be recorded HERE, in the parent shell: the command
    # substitution runs `udid_for_device` in a subshell, so an array it appends to
    # itself would vanish (and `cleanup()` would keep leaking simulators).
    device_info=$(udid_for_device "$device") || { failed=$((failed + 1)); continue; }
    udid="${device_info%% *}"
    [ "${device_info##* }" = "booted-by-us" ] && BOOTED_UDIDS+=("$udid")
    echo "    udid: $udid"
    apply_status_bar "$udid"

    # --- Build ONCE per device -------------------------------------------
    # Compile the app + test bundle a single time; every locale below reuses
    # this via `test-without-building`, turning N builds into 1.
    device_slug="${device// /_}"
    derived="$RESULT_ROOT/derived-$device_slug"
    build_log="$RESULT_ROOT/build-$device_slug.log"
    echo "    building for testing (once)…"
    if ! xcodebuild build-for-testing \
        -workspace "$WORKSPACE" \
        -scheme "$SCHEME" \
        -destination "platform=iOS Simulator,id=$udid" \
        -derivedDataPath "$derived" \
        CODE_SIGNING_ALLOWED=NO \
        > "$build_log" 2>&1; then
        echo "    !! build-for-testing failed (see $build_log)" >&2
        failed=$((failed + 1))
        continue
    fi

    xctestrun=$(find_xctestrun "$derived") || {
        echo "    !! No .xctestrun produced under $derived (see $build_log)" >&2
        failed=$((failed + 1))
        continue
    }
    echo "    xctestrun: $xctestrun"

    # --- Loop locales, reusing the build --------------------------------
    for locale in "${LOCALES[@]}"; do
        lang=$(lang_for_locale "$locale")
        region=$(region_for_locale "$locale")
        # The app-facing locale identifier (`uk_UA`, `pt_BR`) for -AppleLocale.
        app_locale="${lang}_${region}"
        echo "    -- $locale  (lang=$lang region=$region locale=$app_locale)"

        # Pin the language in a per-locale copy of the xctestrun; the shared
        # original is left untouched so the next locale patches from clean.
        # The copy MUST sit in the same directory as the original: the paths
        # inside are relative to `__TESTROOT__`, which xcodebuild resolves from
        # the xctestrun file's own location (moving it elsewhere fails with
        # "Missing test product at …").
        locale_xctestrun="$(/usr/bin/dirname "$xctestrun")/${locale}-$(/usr/bin/basename "$xctestrun")"

        dest="$OUTPUT_ROOT/$locale/$device"
        # Clear ONLY this subdir, so a failure elsewhere can't destroy other
        # locales'/devices' good captures — but clear it BEFORE anything below can
        # bail out. If this locale fails, its directory must end up empty rather
        # than holding the previous run's PNGs: stale images pass the sanity check
        # (they hash as if fresh), and `fastlane` uploads whatever is on disk, so a
        # skipped locale would quietly ship yesterday's — possibly wrong-language —
        # screenshots.
        rm -rf "$dest"
        mkdir -p "$dest"

        if ! patch_xctestrun "$xctestrun" "$locale_xctestrun" "$lang" "$app_locale" "$region"; then
            echo "       !! could not patch the xctestrun for $locale — skipping" >&2
            failed=$((failed + 1))
            continue
        fi

        xcresult="$RESULT_ROOT/${locale}-${device_slug}.xcresult"
        rm -rf "$xcresult"

        # -testLanguage/-testRegion are kept for the `test` (with building) path
        # and for readable logs, but they do NOT do the work here: on this path the
        # xctestrun's own `TestLanguage`/`TestRegion` win — they ship EMPTY, which
        # is why these flags appeared to be ignored — so `patch_xctestrun` sets
        # them in the file. That is what localizes the system furniture (keyboard,
        # system controls); the app itself is localized by the -AppleLanguages
        # launch arguments, and `ScreenshotTests` refuses to capture unless the app
        # confirms it resolved the requested language.
        if xcodebuild test-without-building \
            -xctestrun "$locale_xctestrun" \
            -destination "platform=iOS Simulator,id=$udid" \
            -testLanguage "$lang" \
            -testRegion "$region" \
            -resultBundlePath "$xcresult" \
            CODE_SIGNING_ALLOWED=NO \
            > "$RESULT_ROOT/${locale}-${device_slug}.log" 2>&1; then
            if export_attachments "$xcresult" "$dest"; then
                echo "       captured -> $dest"
                captured=$((captured + 1))
            else
                failed=$((failed + 1))
            fi
        else
            echo "       !! test-without-building failed (see $RESULT_ROOT/${locale}-${device_slug}.log)" >&2
            failed=$((failed + 1))
        fi
    done
    echo
done

# --- Apple Watch --------------------------------------------------------------
# No xcodebuild per locale here: the app is built and installed ONCE per device,
# then each locale × screen is one `simctl launch` + one `simctl io screenshot`.
for device in "${WATCH_DEVICES[@]}"; do
    [ "$RUN_WATCH" -eq 1 ] || break
    echo "==> Watch device: $device"

    # Same reason as the iOS loop: the device-level bailouts below skip the locale
    # loop (and its per-locale clear), so drop the previous run's PNGs up front —
    # otherwise a build/install failure leaves yesterday's set on disk for fastlane
    # to upload. See `clear_device_output`.
    clear_device_output "$OUTPUT_ROOT" "$device" "${LOCALES[@]}"

    device_info=$(udid_for_device "$device") || { failed=$((failed + 1)); continue; }
    udid="${device_info%% *}"
    [ "${device_info##* }" = "booted-by-us" ] && BOOTED_UDIDS+=("$udid")
    echo "    udid: $udid"
    # watchOS simulators ignore most status-bar overrides; the helper already
    # warns and continues rather than failing the run.
    apply_status_bar "$udid"

    device_slug="${device// /_}"
    derived="$RESULT_ROOT/derived-$device_slug"
    build_log="$RESULT_ROOT/build-$device_slug.log"
    echo "    building the watch app (once)…"
    if ! xcodebuild build \
        -workspace "$WORKSPACE" \
        -scheme "$WATCH_SCHEME" \
        -destination "platform=watchOS Simulator,id=$udid" \
        -derivedDataPath "$derived" \
        CODE_SIGNING_ALLOWED=NO \
        > "$build_log" 2>&1; then
        echo "    !! build failed (see $build_log)" >&2
        failed=$((failed + 1))
        continue
    fi

    watch_app=$(find_watch_app "$derived") || {
        echo "    !! No .app produced under $derived (see $build_log)" >&2
        failed=$((failed + 1))
        continue
    }
    echo "    app: $watch_app"

    if ! xcrun simctl install "$udid" "$watch_app" >/dev/null 2>&1; then
        echo "    !! simctl install failed for $watch_app" >&2
        failed=$((failed + 1))
        continue
    fi

    for locale in "${LOCALES[@]}"; do
        lang=$(lang_for_locale "$locale")
        region=$(region_for_locale "$locale")
        app_locale="${lang}_${region}"
        echo "    -- $locale  (lang=$lang region=$region locale=$app_locale)"

        dest="$OUTPUT_ROOT/$locale/$device"
        # Same invariant as the iOS path: clear this subdir up front so a locale
        # that fails ends up EMPTY rather than holding the previous run's PNGs
        # (which fastlane would happily upload).
        rm -rf "$dest"
        mkdir -p "$dest"

        locale_failed=0
        for entry in "${WATCH_SCREENS[@]}"; do
            screen="${entry%%:*}"
            dwell="${entry##*:}"
            if capture_watch_screen "$udid" "$screen" "$dwell" "$lang" "$app_locale" "$dest"; then
                echo "       $screen -> $dest/$screen.png"
            else
                locale_failed=1
            fi
        done

        if [ "$locale_failed" -eq 0 ]; then
            captured=$((captured + 1))
        else
            # A partially-captured locale is not shippable: leave nothing behind
            # rather than a set with a hole (or a wrong-language screen) in it.
            rm -rf "${dest:?}"/*.png
            failed=$((failed + 1))
        fi
    done
    echo
done

# ---------------------------------------------------------------------------
# Sanity check + summary.
# ---------------------------------------------------------------------------

# Backstop only — the run has already refused to capture any locale whose app did
# not resolve the requested language (`assertRequestedLanguageApplied` in
# ScreenshotTests on iOS, `verify_watch_language` on the watch). This re-checks the
# captured bytes and hard-fails on images it cannot identify.
#
# The iOS and watch checks are SEPARATE because the comparison differs: iOS pins
# the clock to 9:41 so whole PNGs are comparable (`check_locales_differ`), whereas
# watchOS bakes an uncontrollable clock into every shot, so the watch check
# compares a status-bar-cropped region and skips the running `01-live` screen
# (`check_watch_locales_differ`). Both run over whatever is on disk, since that is
# what fastlane will upload.
identical=0

# iOS whole-image check, over the iOS devices only.
if [ "$captured" -gt 0 ] && [ "${#DEVICES[@]}" -gt 0 ]; then
    # Only meaningful once at least one iOS device dir exists (a `--watch`-only run
    # leaves none). Guard so that run does not fail on "no output directory".
    if /usr/bin/find "$OUTPUT_ROOT" -type d -path "*/${DEVICES[0]}" -print -quit 2>/dev/null | grep -q .; then
        check_locales_differ "$OUTPUT_ROOT" "${LOCALES[@]}" -- "${DEVICES[@]}" || identical=1
    fi
fi

# Watch cropped check, per watch device, over the byte-checkable (static) screens.
if [ "$captured" -gt 0 ] && [ "${#WATCH_DEVICES[@]}" -gt 0 ]; then
    # Static slugs = WATCH_SCREENS minus WATCH_BYTE_EXCLUDE.
    watch_static_slugs=()
    for entry in "${WATCH_SCREENS[@]}"; do
        slug="${entry%%:*}"
        excluded=0
        for skip in "${WATCH_BYTE_EXCLUDE[@]}"; do
            [ "$slug" = "$skip" ] && { excluded=1; break; }
        done
        [ "$excluded" -eq 0 ] && watch_static_slugs+=("$slug")
    done
    for device in "${WATCH_DEVICES[@]}"; do
        # Only if this watch device actually has output on disk.
        if /usr/bin/find "$OUTPUT_ROOT" -type d -path "*/$device" -print -quit 2>/dev/null | grep -q .; then
            check_watch_locales_differ "$OUTPUT_ROOT" "$device" "$WATCH_CROP_STRIP_PX" \
                "${LOCALES[@]}" -- "${watch_static_slugs[@]}" || identical=1
        fi
    done
fi

echo "==> Done"
echo "    captured combinations : $captured"
echo "    failed combinations   : $failed"
echo "    screenshots           : $OUTPUT_ROOT/"
echo "    (temp logs & result bundles under $RESULT_ROOT are removed on exit)"

if [ "$failed" -gt 0 ] || [ "$identical" -ne 0 ]; then
    exit 1
fi
