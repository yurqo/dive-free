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
# Because a silent regression here is so expensive, it is verified twice:
#   1. DIRECTLY, and this is the one that matters — the app publishes its RESOLVED
#      localization (`Bundle.main.preferredLocalizations.first`, DEBUG +
#      `--screenshot-demo` only) and `ScreenshotTests` fails the locale's run
#      unless it matches what was requested. A failed locale lands in `failed`
#      below, which forces `exit 1`.
#   2. Indirectly, as a backstop — a cross-locale md5 check over the exported PNGs
#      (see `check_locales_differ`). Kept, but never trusted on its own: image
#      diffs are defeated by rendering noise, and on the wrong-language run a few
#      jittering map-thumbnail pixels were enough to clear every `en` pair.
#
# Prerequisites:
#   - `tuist generate` has been run (DiveFree.xcworkspace + ScreenshotTests
#     scheme exist).
#   - Xcode 16+ (for `xcrun xcresulttool export attachments`). See the export
#     step for the `xcparse` fallback if that subcommand is unavailable.
#
# This is a developer tool: readability and correctness over cleverness. It is
# idempotent — each locale/device output subdir is cleared just before it is
# (re-)written, so a partial failure leaves earlier good captures untouched (and a
# locale that fails leaves an EMPTY dir, never last run's PNGs). Output for device
# names no longer in `DEVICES` is pruned up front — see `prune_stale_device_dirs`.

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
    "iPhone 17 Pro Max"
    "iPad Pro 13-inch (M5)"
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

# Delete `screenshots/<locale>/<device>` directories whose device is no longer in
# `DEVICES`, and report what was removed.
#
# WHY this is not cosmetic: renaming a device (as `DEVICES` above just did —
# `iPhone 16 Pro Max` -> `17 Pro Max`, `iPad Pro 13-inch (M4)` -> `(M5)`) leaves
# the old directories in
# place, and NOTHING downstream notices. `check_locales_differ` only iterates the
# configured `DEVICES`, so it never inspects them — but the Fastfile's
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
    [ "$pruned" -gt 0 ] && echo "    pruned $pruned stale device dir(s) not in DEVICES"
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

# SECONDARY net: fail the run if two locales produced byte-identical screenshots
# of the same screen.
#
# The PRIMARY guarantee is in the test itself — `ScreenshotTests` asks the app for
# its resolved localization and fails the locale's xcodebuild run if it is not the
# one requested (see `assertRequestedLanguageApplied`). This image check exists
# only to catch what that cannot: a bug where the language applies to the app but
# the *captures* still come from a stale/shared source.
#
# Screenshots are compared per device and per *logical* screen, keyed by the
# "NN-slug" taken from each device dir's manifest.json
# (`suggestedHumanReadableName`, normalized exactly like the Fastfile's
# `readable_name_for`), because the exported PNG filenames are random UUIDs.
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

def slug_hashes(device_dir):
    """{"03-trips": "<md5>"} for one <locale>/<device> directory.

    Every way this can fail to produce a full, keyed set raises Unusable. Nothing
    here is best-effort ON PURPOSE: anything less than "every PNG mapped to a
    distinct slug" means the loop below compares fewer screens than it appears to,
    and a check that silently compares nothing prints "passed" — the exact shape of
    the failure that shipped 80 wrong-language screenshots. The three ways out:

      - no PNGs at all: the locale/device produced nothing (a failed or skipped
        combination), so there is nothing to conclude and it must not read as a
        clean bill of health for that locale;
      - PNGs but nothing mapped: no/unreadable manifest.json, so keys would fall
        back to the exported random-UUID filenames, which never match across
        locales — every comparison then trivially "passes". The `xcparse` fallback
        documented in the header produces precisely that state;
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

    unmapped = [entry for entry in pngs if entry not in names]
    if len(unmapped) == len(pngs):
        raise Unusable(
            "%s: %d PNG(s) but no usable slug map (missing/unreadable "
            "manifest.json)" % (device_dir, len(pngs))
        )
    if unmapped:
        raise Unusable(
            "%s: %d of %d PNG(s) missing from manifest.json (%s) — they would be "
            "silently left out of the comparison"
            % (device_dir, len(unmapped), len(pngs), ", ".join(unmapped))
        )

    hashes = {}
    for entry in pngs:
        slug = names[entry]
        with open(os.path.join(device_dir, entry), "rb") as handle:
            digest = hashlib.md5(handle.read()).hexdigest()
        if slug in hashes:
            raise Unusable(
                "%s: two screenshots map to the same slug %r — the manifest "
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
    print("    Do NOT upload these. `-testLanguage`/`-testRegion` on the command", file=sys.stderr)
    print("    line do NOT localize the app on the `test-without-building", file=sys.stderr)
    print("    -xctestrun` path; the language must arrive via the patched", file=sys.stderr)
    print("    xctestrun (TestLanguage/TestRegion + SCREENSHOT_LANGUAGE /", file=sys.stderr)
    print("    SCREENSHOT_LOCALE -> -AppleLanguages/-AppleLocale in", file=sys.stderr)
    print("    ScreenshotTests.setUpWithError). Check that all of it is still wired.", file=sys.stderr)
    sys.exit(1)

print("==> Cross-locale sanity check passed (%d screen comparisons, none identical "
      "across locales)" % compared)
' "$@"
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

# Drop output from device names we no longer capture (see the function comment:
# fastlane would otherwise upload both generations).
prune_stale_device_dirs "$OUTPUT_ROOT" "${DEVICES[@]}"

captured=0
failed=0

for device in "${DEVICES[@]}"; do
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

# ---------------------------------------------------------------------------
# Sanity check + summary.
# ---------------------------------------------------------------------------

# Backstop only — the run has already refused to capture any locale whose app did
# not resolve the requested language (see `assertRequestedLanguageApplied` in
# ScreenshotTests). This re-checks the exported bytes, and also hard-fails if the
# export produced images it cannot identify (see `check_locales_differ`).
identical=0
if [ "$captured" -gt 0 ]; then
    check_locales_differ "$OUTPUT_ROOT" "${LOCALES[@]}" -- "${DEVICES[@]}" || identical=1
fi

echo "==> Done"
echo "    captured combinations : $captured"
echo "    failed combinations   : $failed"
echo "    screenshots           : $OUTPUT_ROOT/"
echo "    (temp logs & result bundles under $RESULT_ROOT are removed on exit)"

if [ "$failed" -gt 0 ] || [ "$identical" -ne 0 ]; then
    exit 1
fi
