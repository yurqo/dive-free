#!/usr/bin/env bash
# PreToolUse hook — blocks `gh pr merge` unless all CI checks have passed.
# Reads Claude Code hook JSON from stdin; outputs a deny object to stdout to
# block the call, or exits 0 silently to allow it.

set -euo pipefail

INPUT=$(cat)
COMMAND=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // ""')
CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // ""')

[[ -z "$COMMAND" ]] && exit 0

# Only intercept gh pr merge calls.
printf '%s' "$COMMAND" | grep -qE '\bgh pr merge\b' || exit 0

deny() {
    jq -nc --arg reason "$1" \
        '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":$reason}}'
    exit 0
}

[[ -n "$CWD" ]] && cd "$CWD"

# Extract an explicit PR number, e.g. `gh pr merge 24 --squash`.
PR_NUM=$(printf '%s' "$COMMAND" | grep -oE '\bgh pr merge[[:space:]]+([0-9]+)' | grep -oE '[0-9]+$' || true)

if [[ -n "$PR_NUM" ]]; then
    CHECKS=$(gh pr checks "$PR_NUM" --json name,bucket,state 2>/dev/null) \
        || deny "Could not fetch CI checks for PR #$PR_NUM — merge blocked until checks can be verified."
else
    CHECKS=$(gh pr checks --json name,bucket,state 2>/dev/null) \
        || deny "Could not fetch CI checks for the current branch PR — merge blocked until checks can be verified."
fi

# No checks at all means CI hasn't run yet.
if [[ $(printf '%s' "$CHECKS" | jq 'length') -eq 0 ]]; then
    deny "No CI checks found for this PR — merge blocked until the CI pipeline has run."
fi

# Collect any check not in a terminal passing state.
# bucket values: "pass", "skipping", "fail", "pending"
NOT_PASSED=$(printf '%s' "$CHECKS" | jq -r '
    .[] | select(.bucket != "pass" and .bucket != "skipping")
        | .name + " [" + .bucket + "]"
')

if [[ -n "$NOT_PASSED" ]]; then
    SUMMARY=$(printf '%s' "$NOT_PASSED" | tr '\n' ', ' | sed 's/, $//')
    deny "CI checks not all passing — merge blocked. $SUMMARY"
fi

exit 0
