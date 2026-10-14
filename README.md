# Offline Notes

An offline-first Flutter notes app with attachments. It syncs against the provided
`lib/fake_server.dart`, which is copied in unchanged.

## Architecture

```
screens / widgets  ->  DatabaseHelper (SQLite)  <->  SyncEngine  <->  FakeServer
```

- **Screens** read and write only the local database through `DatabaseHelper`.
  Each write saves the row change and its outbox entry in one transaction.
- **`SyncEngine`** (`lib/data/sync_engine.dart`) is the only code that calls the
  server. It has no Flutter imports, so it is unit tested with `flutter test`.
- **Tables:** `notes`, `attachments`, `outbox` and `sync_meta` (one pull cursor per
  server table). Each note and attachment stores `version` (the server version my
  edit is based on) and `sync_status` (synced / pending / failed / conflict).
- **IDs** are UUID v4 values made on the device before saving.
- **Triggers:** sync runs on app start, app resume, pull-to-refresh, reconnect (the
  Offline switch turning off), after each local change, and on a 5s timer that
  retries entries whose backoff has expired.

## Outbox model

Each outbox entry has: id (auto-increment, which gives FIFO order), entity type
and id, note id, op (`insert`, `update`, `delete`, `upload`, `set_path`), payload
(JSON), base version, lane, status (queued / in_flight / done / failed), attempts,
next attempt time, last error and created time.

- **Ordering:** FIFO per note. Once an entry of a note can't run, later entries of
  the same note wait, while other notes carry on.
- **Dependencies:** note create → attachment row (FIFO in the data lane) → file
  upload (waits until the attachment row has a server version) → `set_path` (queued
  only once the upload succeeds). So `storage_path` is never set before the file
  exists.
- **Lanes:** the data lane and the file lane each have one worker. They run in
  parallel, so a large upload never holds up note text.
- **One consumer:** each lane has a busy flag, so a second trigger during a run
  does nothing.
- **Crash recovery:** on start, `in_flight` entries go back to `queued`. Resending is
  safe: `AlreadyExists` on create means the earlier attempt landed. On update, a
  `Conflict` whose server row already holds my payload is my own lost write, not a
  real conflict.
- **Retry:** `NetworkError` and `ConstraintViolation` retry with exponential backoff
  and jitter (about 1s, 2s, 4s, 8s, capped at 60s). After 5 attempts, or an error
  retrying can't fix, the entry becomes `failed`. It is shown in the queue
  inspector, which offers a retry. Entries are never dropped silently.
- **Coalescing:** an edit is folded into an unsent create or update for the same
  note. A delete before the create was ever sent removes the note and its entries
  locally; the server never saw it, so no tombstone is needed.
- **Done** is set only after the server accepts the call.

## Pull

`changesSince` runs per table, page by page (200 rows). Each page and its cursor
are saved in one transaction, so the cursor never moves past rows that weren't
stored. Tombstones are kept locally as `deleted = 1`. A row with pending outbox
entries is never overwritten; the version-checked push detects the conflict
instead.

## Conflict policy, and why

No device clocks are used. On a `Conflict` (the server moved on), the note keeps
**both** versions: mine in the normal columns, theirs in `server_*` columns. The
note shows the amber conflict state, and the editor offers **Keep mine** (push my
version on top of theirs) or **Keep theirs**. Delete versus edit uses the same
flow: a note deleted on the other device shows "Deleted on the other device", and
I choose to restore it or delete it.

Why: it is the simplest policy that can never silently lose either side, and the
person who knows which edit matters makes the decision. Field-level merge would be
the next step.

## Attachments

A picked file is copied straight into the app support folder, so it shows offline.
The upload path is `{noteId}/{attachmentId}`, so a retried upload just overwrites.
On a fresh install, attachment rows come back through pull, and files download only
when their note is opened, then stay cached.

## Debug menu (bug icon)

- The four fault switches
- Sync now
- Queue inspector, with retry-failed and clear-done
- Wipe local data (the server folder is kept)
- "Other device" edit or delete for each note, via `simulateOtherDeviceEdit`

## Assumptions and known gaps

- "Reconnect" means the Offline switch turning off. A real app would also listen
  to `connectivity_plus`.
- Deleting a note doesn't tombstone its attachments on the server yet.
- A large file is uploaded in one call. The next step would be resumable
  `startUpload` / `uploadChunk` with progress.
- After a manual "retry failed", a later edit may coalesce into an update that had
  actually landed. That shows up as a conflict (both sides kept), not as data loss.
- If another device changes a note while the user is typing in it, the user's save
  is based on the newer version. The fix is to remember the version when editing
  starts.
- No background sync (workmanager / BGTaskScheduler) and no cache size limit.
- A local schema change drops and recreates local tables (dev only). Data comes
  back from the server folder.

## Run

```
flutter pub get
flutter test
flutter run
```
