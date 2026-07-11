# Phase 6 planning — quick-setup wizard, sync preview, ignore rules,
# version-restore UI

**Status:** plan only, nothing implemented. Companion to `Roadmap.md` §Phase 6
(read that first for the summary table) and `ARCHITECTURE.md` (engine
internals). Written 2026-07-11 after an audit of the current codebase against
the proposed bundle.

---

## 0. Headline finding — the bundle is not 4 equal-sized items

The proposal groups four things together because they're all additive and
engine-safe. True, but they are **not equally-sized work**:

| Item | Real status |
|---|---|
| Pause | ✅ **already shipped** (Phase 1). `AppState.isPaused` / `pauseSync()` / `resumeSync()`, wired to a dashboard button. Nothing to build. |
| Sync Now | ✅ **already shipped** (Phase 3/5). `AppState.syncFolderNow(pair)`, wired per-pair in `folder_pairs_screen.dart`. Nothing to build. |
| Sync preview | 🆕 genuinely new, but cheap — see §3. |
| Ignore rules | 🆕 genuinely new, moderate — see §4. |
| Version-restore UI | 🆕 genuinely new, and bigger than it looks — see §5. There's dead infrastructure (`moveToVault`) that helps, but it changes the honest scope. |
| Quick-setup wizard | 🆕 genuinely new, low engine risk, one fragile platform detail — see §6. |

Recommended reading order below is value × risk, using what was actually
found in the code — not the original bundle order.

---

## 1. Engine-safety re-check (per Roadmap §0)

None of the four new items touch `indexDiff`, `_applyRemoteTombstone`,
`upsertLocal`, `confirmLocalObservation`, or version-vector ordering logic,
**with one flagged exception**: version-restore's "restore a deleted file"
half wants a hook inside `_applyRemoteTombstone` itself. That's called out
explicitly in §5.3 as a decision for Aminul, not assumed.

Everything else in this plan is a new code path that can be deleted without
touching the engine, per the existing checklist.

---

## 2. Recommended sequencing

1. **6.1 Sync preview** — cheapest, reuses existing plumbing 1:1, zero schema
   changes, zero new dependencies.
2. **6.2 Ignore rules** — one clean injection point, but needs a design
   decision on retroactive behavior before coding (see §4.4).
3. **6.3 Quick-setup wizard** — pure UI composition; the one platform detail
   (initial-URI hint) is best-effort, doesn't block shipping without it.
4. **6.4 Version-restore UI** — largest, and gated on Aminul picking one of
   the two options in §5.3 before a session starts writing code.

Pause/Sync Now need no phase — see §0.

---

## 3. Sync preview

**What it is:** before a sync fires (auto or via "Sync Now"), show what
*would* happen — N files to fetch, M to push, sizes — without moving bytes.

**Why it's cheap:** `index_diff.dart`'s `indexDiff()` is a **pure function**
— no DB writes, no side effects, takes two in-memory snapshots and returns a
list of `Need`. And the engine already exposes the exact snapshot a preview
needs, read-only:

```dart
// engine.dart:1719 — already public, already exists
Map<String, IndexEntry>? peerLiveFor(String pairId) => _peerLive[pairId];
```

So the whole feature is: for a connected pair, call `db.localSnapshot(deviceId)`
(already public) + `engine.peerLiveFor(pair.id)` (already public), pass both
into the *existing, unmodified* `indexDiff()`, and render the result. No new
wire message, no new DB table, no engine edit at all — this is 100% new UI +
one small new helper method on `AppState` that wires the two together.

**What it can't show:** the *reverse* direction (what the peer would pull
from us) without also calling `indexDiff` with local/peer swapped — trivial,
same function, just swap the two lists.

**Caveat to set expectations on:** `_peerLive[pairId]` is only populated
once a peer has connected and sent at least one `Index`/`IndexUpdate` this
session (see `engine.dart:1496` `putIfAbsent`) — so "preview" is only
meaningful while paired-and-recently-connected, not for an offline pair.
Handle the `null` case as "connect first to preview" in the UI rather than
silently showing an empty list.

**Files:**
- `lib/src/app_state.dart` — new `previewSync(FolderPair pair)` method
  returning something like `({List<Need> toFetch, List<Need> peerWouldFetch})`.
- `lib/src/ui/folder_pairs_screen.dart` — new "Preview" button/sheet next to
  the existing "Sync Now" button.

**Tests:** none needed against the engine (indexDiff already has its own
test file, `index_diff_test.dart`, untouched). A widget test for the new
preview sheet is optional and follows the same pattern as the rest of `ui/`
(none of which currently has widget-test coverage — see `PROGRESS.md`
2026-07-10 entry on `widget_test.dart` being first-frame-only).

**Effort:** small — well under a day.

---

## 4. Ignore rules (glob / extension / size)

**What it is:** per-pair rules so files matching a pattern, extension, or
size threshold are never synced.

### 4.1 Where it hooks in

`scanner.dart`'s `IndexScanner.scan()` already has exactly the right shape
of check at line 87:

```dart
if (_isInternalArtefact(rel)) continue;
```

Ignore rules slot in immediately after, at the same level — a path that
matches a rule is skipped **before** it's ever hashed or passed to
`upsertLocal`. This means an ignored file never enters the Index DB, never
gets a version vector, never enters the needs-queue. It's the same
"never-indexed" shape `.syncstate`/`.syncversions` already use, just
user-configurable instead of hardcoded.

### 4.2 Schema

Extend `FolderPair` (`wire.dart`) with three new optional fields, all
defaulting to empty so existing saved configs parse unchanged:

```dart
final List<String> ignoreGlobs;      // e.g. ["node_modules/**", "*.tmp"]
final List<String> ignoreExtensions; // e.g. [".tmp", ".log"]
final int? maxFileSizeBytes;         // null = no cap
```

`toJson`/`fromJson` follow the existing pattern (`peerDeviceId` is already
nullable-with-default there for the same backward-compat reason).

**Sync question:** should ignore rules be peer-agreed (like `direction`,
negotiated via `folderInvite`/`folderAccept`) or purely local (each side sets
its own, independently)? Recommend **purely local** for v1 — simpler, and a
legitimate use case is "I don't want screenshots synced to MY phone" without
needing the PC's agreement. Flagging as the default rather than assuming;
easy to revisit.

### 4.3 New dependency

No existing package does glob matching. Add `glob: ^2.1.2` (small, from the
dart.dev team, zero transitive risk) — consistent with the existing pattern
of adding a small package per phase (`window_manager`/`tray_manager` for
Phase 1, `flutter_local_notifications` for Phase 3).

### 4.4 Open design question — retroactive ignore (needs Aminul's call)

If a rule is added *after* matching files are already synced, what should
happen to those files?

- **Scanner sees them stop appearing** in `diskEntries` once skipped.
- The existing tombstone sweep (`scanner.dart:112-122`, uses
  `localLivePaths`) checks "was this live before, is it seen now" — a
  newly-ignored-but-already-synced path would look exactly like a local
  delete and get **tombstoned and delete-propagated to the peer**.

That's very likely not what "ignore" means to most users (ignore = "stop
tracking new changes", not "delete this from the other device"). Recommended
default: an ignored path is still added to `seenPaths` (so the sweep leaves
it alone — frozen at its last-synced state) but is never re-hashed or
re-upserted, so further local edits to it stop propagating. This needs one
line at the injection point:

```dart
if (_isInternalArtefact(rel)) continue;
if (matchesIgnoreRule(rel)) {
  seenPaths.add(rel); // freeze, don't tombstone
  continue;
}
```

**Confirm this is the behavior you want before implementation** — the
alternative (ignoring == actively removing from the peer too) is a valid
different feature, just a different one.

**Files:**
- `lib/src/protocol/wire.dart` — `FolderPair` schema.
- `lib/src/sync/scanner.dart` — injection point + a small matcher helper.
- `lib/src/ui/folder_pairs_screen.dart` — a rules editor (three simple
  lists/fields per pair).
- `pubspec.yaml` — add `glob`.

**Tests:** new `test/ignore_rules_test.dart` in the same logic-only style as
`scanner_test.dart` — no sockets/SAF, real `IndexDb` + scanner, asserting
(a) a globbed file never gets a row, (b) a previously-synced file that
becomes ignored keeps its row and isn't tombstoned, (c) size-cap skips large
files.

**Effort:** small–medium, mostly the UI (three list editors) and the
retroactive-ignore test. Once §4.4 is confirmed, straightforward.

---

## 5. Version-restore UI (including restore-deleted-file)

This is the item worth being most careful about — the framing "reads from
data the engine already produces" undersells it. The data **isn't** already
produced; the code that would produce it exists but has never been wired up.

### 5.1 What already exists (and is dead)

Both `FileSystemAccess` implementations already define a versioning vault:

```dart
// manifest.dart:64-65 (Windows) and saf_access.dart:115 (Android)
/// Move a file to the conflict vault directory (under .syncversions).
Future<String> moveToVault(String rootPath, String relPath) async { ... }
```

It timestamps the existing file into `.syncversions/<dir>/<name>.<stamp>.<ext>`
before it would be overwritten or removed. `index_diff.dart`'s own comment
says *"Phase 4 backs up the loser's pre-conflict copy to `.syncversions`"* —
but Phase 4 is marked ✅ complete in the roadmap and **`moveToVault` is never
called from anywhere in the engine** (confirmed by grepping every call site
in `lib/src/`). This is the same "docs said it happens, code never did it"
gap the 2026-07-10 wake-lock audit found in a different feature — worth
noting in `ARCHITECTURE.md` regardless of whether Phase 6 proceeds.

### 5.2 What version-restore actually needs

1. **Wire `moveToVault` in** at the point(s) where Conduit overwrites or
   deletes a file under its own control.
2. **A UI** to browse `.syncversions/` per pair and restore an entry back to
   its live location.
3. **Some retention/pruning policy** — there currently is none. `.syncversions`
   will grow forever. Even just "keep last N versions per file" needs a small
   sweep somewhere; out of scope for a first cut, but flag it to Aminul as a
   known gap rather than silently shipping unbounded disk growth.

### 5.3 The open decision: restoring *edits* vs. restoring *deletes*

These need two different hooks, with two different risk levels:

**Restoring a previous version of an edited file** — hooks cleanly into
`block_transfer.dart`'s `_replacePartWithFinal` (the function that renames
`.syncpart` over the final file once a fetch completes). Before the rename,
if `dest` already exists, vault it first. This function is **not** on the
do-not-touch list and is narrow/self-contained. Low risk.

**Restoring a deleted file** — the only point where Conduit itself controls
a disk delete is inside `_applyRemoteTombstone` (`engine.dart:1622`, the
`fs.delete()` call at line 1669) and the reconcile-sweep
`_propagateRemoteDeletes` (line 1699). A *local* delete (user deletes via
Explorer/Files app) can't be vaulted at all — by the time the watcher
notices, the bytes are already gone; there's nothing left to snapshot. So
"restore a deleted file" only works for deletes that arrived *from a peer*
(received tombstones), and the only hook for that is inside the function
Aminul explicitly asked not to touch.

Two honest options, not picked for you:

- **(a)** Add one best-effort, try/caught line immediately before each
  existing `fs.delete()` call in `_applyRemoteTombstone` /
  `_propagateRemoteDeletes` — zero changes to decision logic, DB writes, or
  version-vector comparisons, purely an added disk snapshot before an
  existing disk operation. Technically touches the function's source.
- **(b)** Drop "restore a peer-deleted file" from v1 scope; ship only
  "restore a previous version of an edited file" (§ above, fully clear of
  the constraint). Add delete-restore later as its own reviewed change.

**Recommendation if asked to pick: (b) for the first cut**, then revisit (a)
as a small, isolated, easy-to-review follow-up once it can be looked at on
its own — rather than bundling a boundary-case decision into a larger
feature's first version.

### 5.4 Files (assuming option (b) scope)

- `lib/src/sync/block_transfer.dart` — `_replacePartWithFinal`: vault
  existing `dest` before rename, best-effort (log + continue on failure,
  never block the transfer on a vault write failing).
- `lib/src/ui/` — new screen: browse `.syncversions/<pair>/`, show
  timestamped entries per file, "Restore" button (copies the vault entry
  back to the live path; does **not** delete the vault entry, so restoring
  twice or restoring the wrong one is non-destructive).
- No DB/wire changes — the vault is filesystem-only, matching how
  `.syncversions` already works.

### 5.5 Tests

- Extend `block_transfer_test.dart` with a case: fetching a file that
  already exists locally results in the old bytes present under
  `.syncversions/` with the expected naming, and the new bytes at the live
  path.
- A manual restore-flow check (copy vault entry → live path, confirm scanner
  picks it up as a local edit on next scan) — hard to unit-test cleanly
  since it crosses into real filesystem behavior; note as manual-verify like
  the Phase 0.4 wake-lock code.

**Effort:** medium (edit-restore only, option b) to large (if delete-restore
is added later under option a) — plus real product decisions (retention
policy) that aren't code at all.

---

## 6. Quick-setup wizard (camera/screenshot backup presets)

**What it is:** a couple of taps to create a `sendOnly` `FolderPair` from a
device's camera/screenshot folder to a chosen PC folder, instead of the
general "add pair" flow.

### 6.1 The easy 90%

This is almost entirely composition of what already exists:
- `FolderPair(direction: SyncDirection.sendOnly, ...)` — the enum value
  already exists (`wire.dart`).
- The existing add-pair flow (`folder_pairs_screen.dart` `_showPairDialog`)
  already does folder-pick + `state.addFolderPair(pair)`.
- A wizard is a thin screen that pre-fills `direction: sendOnly` and a
  suggested name ("Camera backup" / "Screenshots"), then hands off to the
  same picker + `addFolderPair` call already in use.

### 6.2 The one fragile detail — don't oversell it

The nice-to-have is pre-navigating Android's system folder picker straight
to `DCIM/Camera` or `Pictures/Screenshots` instead of making the user
browse. `ACTION_OPEN_DOCUMENT_TREE` supports an `EXTRA_INITIAL_URI` hint,
and `MainActivity.kt`'s existing picker channel (`CH_PICK_TREE`, method
`"pick"`) doesn't currently pass one — adding an optional parameter is
additive and backward compatible (omit it, behavior is unchanged).

But constructing a valid initial URI for a tree the app doesn't have a grant
for yet is inconsistent across OEMs/Android versions in practice. Scope this
as **best-effort**: try the hint, and if the picker opens to the same
generic root it always did, that's an acceptable, non-broken fallback — not
a bug to chase. The wizard should ship a short instruction line ("select
DCIM → Camera") regardless of whether the hint works, so it's never the only
way the user finds the right folder.

**Files:**
- New `lib/src/ui/quick_setup_wizard.dart` (or a dialog within
  `folder_pairs_screen.dart` — small enough either way, lean toward a
  separate file for discoverability).
- `MainActivity.kt` — optional `initialUri` param on the `pick` channel
  method.
- `lib/src/platform/saf_access.dart` — plumb the optional hint through.

**Tests:** none engine-side (pure UI + platform-channel wiring, same
category as the rest of `ui/`, which has no widget-test coverage today).

**Effort:** small, plus the platform-channel change is a few lines and
optional to land at all in a first cut (the wizard works fine without the
hint, just requires one extra tap to browse to the folder).

---

## 7. Summary table for the roadmap entry

| # | Item | Real effort | Blocking question |
|---|---|---|---|
| 6.1 | Sync preview | Small | none |
| 6.2 | Ignore rules | Small–medium | retroactive-ignore semantics (§4.4) |
| 6.3 | Quick-setup wizard | Small | none (initial-URI hint is optional/best-effort) |
| 6.4 | Version-restore UI | Medium (edit-only) / Large (+ delete-restore) | scope choice (§5.3) + retention policy (§5.2.3) |
| — | Pause | **Done, Phase 1** | — |
| — | Sync Now | **Done, Phase 3/5** | — |
