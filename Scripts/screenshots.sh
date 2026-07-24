#!/usr/bin/env bash
#
# screenshots.sh — capture App Store / marketing screenshots for DiveFree.
#
# Runs the standalone `ScreenshotTests` UI-test target across every supported
# locale × device, applies a clean 9:41 status bar, and exports the captured PNG
# attachments into `screenshots/<locale>/<device>/`.
#
# The test launches the app with `--screenshot-demo`, which (DEBUG-only) boots a
# fresh in-memory store seeded with deterministic demo content, so the output is
# reproducible and never touches real user data.
#
# Efficiency: the app is compiled ONCE per device with `build-for-testing`
# (producing an `.xctestrun`), then each locale reuses that build via
# `test-without-building`. That turns N locales × M devices *builds* into just M.
#
# Prerequisites:
#   - `tuist generate` has been run (DiveFree.xcworkspace + ScreenshotTests
#     scheme exist).
#   - Xcode 16+ (for `xcrun xcresulttool export attachments`). See the export
#     step for the `xcparse` fallback if that subcommand is unavailable.
#
# This is a developer tool: readability and correctness over cleverness. It is
# idempotent — each locale/device output subdir is cleared just before it is
# (re-)written, so a partial failure leaves earlier good captures untouched.

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration — edit these to taste.
# ---------------------------------------------------------------------------

WORKSPACE="DiveFree.xcworkspace"
SCHEME="ScreenshotTests"

# Supported locales. Each maps to an Xcode -testLanguage / -testRegion pair via
# the helpers below. NOTE: this is the OUTPUT-folder key (what ASC expects), not
# necessarily the -testLanguage code — see `lang_for_locale` for the Portuguese
# case where the folder stays `pt-BR` but the app localizes to `pt`.
LOCALES=(en es fr it de pt-BR ja uk)

# Devices to capture on. Names must match `xcrun simctl list devicetypes`
# (and a matching simulator must exist — `xcrun simctl list devices`). Edit
# freely; a 6.9" iPhone and a 13" iPad cover the App Store required sizes.
DEVICES=(
    "iPhone 16 Pro Max"
    "iPad Pro 13-inch (M4)"
)

# Output roots (git-ignored — see .gitignore).
OUTPUT_ROOT="screenshots"
# Temporary result bundles / build products / logs land here; cleaned up on exit.
RESULT_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/divefree-screenshots.XXXXXX")"

# UDIDs of simulators THIS script booted (so the EXIT trap only shuts those
# down and leaves ones the user already had booted alone).
BOOTED_UDIDS=()

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
# if needed (the status-bar override requires a booted device). Records booted
# UDIDs for cleanup. Prints the UDID on stdout; on failure prints an actionable
# error and returns non-zero.
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

    # Boot it if it is not already booted. Detect whether we booted it (so the
    # EXIT trap only shuts down sims we started).
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
        BOOTED_UDIDS+=("$udid")
    fi
    # Wait until fully booted so the status-bar override sticks.
    xcrun simctl bootstatus "$udid" -b >/dev/null 2>&1 || true

    echo "$udid"
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

# Locate the `.xctestrun` file produced by `build-for-testing` under a
# derived-data path. Prints its path; returns non-zero if none is found.
find_xctestrun() {
    local derived="$1"
    local found
    found=$(/usr/bin/find "$derived/Build/Products" -maxdepth 1 -name "*.xctestrun" 2>/dev/null | head -n 1)
    [ -n "$found" ] || return 1
    echo "$found"
}

# ---------------------------------------------------------------------------
# Main.
# ---------------------------------------------------------------------------

echo "==> Screenshot capture"
echo "    workspace : $WORKSPACE"
echo "    scheme    : $SCHEME"
echo "    locales   : ${LOCALES[*]}"
echo "    devices   : ${DEVICES[*]}"
echo "    results   : $RESULT_ROOT"
echo

mkdir -p "$OUTPUT_ROOT"

captured=0
failed=0

for device in "${DEVICES[@]}"; do
    echo "==> Device: $device"

    udid=$(udid_for_device "$device") || { failed=$((failed + 1)); continue; }
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
        echo "    -- $locale  (lang=$lang region=$region)"

        dest="$OUTPUT_ROOT/$locale/$device"
        # Clear ONLY this subdir just before writing it, so a failure elsewhere
        # can't destroy other locales'/devices' good captures.
        rm -rf "$dest"
        mkdir -p "$dest"

        xcresult="$RESULT_ROOT/${locale}-${device_slug}.xcresult"
        rm -rf "$xcresult"

        if xcodebuild test-without-building \
            -xctestrun "$xctestrun" \
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

# ---------------------------------------------------------------------------
# Summary.
# ---------------------------------------------------------------------------

echo "==> Done"
echo "    captured combinations : $captured"
echo "    failed combinations   : $failed"
echo "    screenshots           : $OUTPUT_ROOT/"
echo "    (temp logs & result bundles under $RESULT_ROOT are removed on exit)"

if [ "$failed" -gt 0 ]; then
    exit 1
fi
