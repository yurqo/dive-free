# Watch session sync

All completed sessions use WatchConnectivity `transferFile`, regardless of length.
The JSON payload preserves every depth, track, heart-rate, temperature and note
sample. File metadata contains only transfer/session IDs and the explicit resend
flag. Voice-note recordings continue to transfer as separate audio files.

A local Application Support outbox persists each payload until the iPhone sends a
saved-session acknowledgement. Transport success alone does not clear the pending
badge or make a session eligible for Watch retention. Immutable snapshots prevent
updates to a pending payload from changing a file the OS is reading.

Activation, reconnection and returning to the Watch app automatically retry all
unconfirmed sessions. Queued files are adopted across relaunch and aren't enqueued
again while the OS owns them. Each Watch session shows its own sync status above
Re-send to iPhone, using persisted saved-session receipts rather than the global
pending count. Immediate failures have a bounded retry budget;
a new recovery opportunity renews that budget. Existing manual resend controls
remain available. The Watch database also recovers old sessions rejected before
the durable outbox was introduced.

New sends never use session dictionaries. The receiver still accepts legacy
session dictionaries, and the sender migrates old queued dictionaries to files
only after saving a durable copy. Lightweight acknowledgements, deletions and
note mutations still use their existing control messages.

Verification covers intact 42-minute and four-hour payloads, durable import,
relaunch, queue loss, duplicate delivery, refreshed payloads, explicit resends,
deletion, storage failure and exhausted retries. Simulator tests use injected
transports; real WatchConnectivity delivery must be tested with the same updated
build installed on a paired iPhone and Watch.
