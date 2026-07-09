# Work Progress Log (Claude session)

> Running log of what's been done, in-progress, and next. Updated at every
> checkpoint — never left in a half-written state. Newest entries at the top.

---

## 2026-07-10 — Session start

**Environment notes (read first, affects everything below):**
- No `flutter`/`dart` SDK available in this sandbox, and no network path to
  fetch it (network egress is allowlisted to package registries like
  pypi/npm/crates/github — no Flutter SDK distribution host). **This means I
  cannot run `flutter analyze`, `flutter test`, or `flutter build`.**
- I also have no push credentials for `johnchk250/Conduit` — I can commit
  locally so nothing is left unsaved, but pushing to GitHub needs you to
  either pull my local commits or give me a token.
- Given this, my work this session is **manual code review + careful static
  checking** (reading call sites, signatures, imports, brace balance —
  the same discipline the prior session used for the Phase-4 send-widget
  work), not automated test runs. I'll flag anything that needs a real
  `flutter analyze`/`flutter test`/`flutter build` pass on your machine
  before shipping.

**State found on clone:**
- Repo: `johnchk250/Conduit`, branch `main`, 3 commits, clean working tree.
- `Roadmap.md`: Phases 0–5 all marked ✅ complete (through 2026-06-27).
- `docs/2026-07-05-send-widget-and-throughput.md`: describes a Phase-4
  follow-on (compact "send widget" popup + TCP_NODELAY + pipelined block
  fetch for ad-hoc transfers) that was **written and reviewed without a
  working Flutter install** — the doc's own §6 explicitly asks for
  `_run_analyze.bat` / `_run_test.bat` to be run before shipping. That
  hasn't happened yet (no HANDOFF doc or changelog entry confirms it).
- All files mentioned in that doc exist in the tree (`peer_session.dart`,
  `block_transfer.dart`, `file_send.dart`, `app_state.dart`,
  `dashboard_screen.dart`, `send_flow_view.dart`, `send_panel.dart`,
  `send_widget_screen.dart`, `tray.dart`, `windows/runner/main.cpp`).

**Plan for this session:**
1. ✅ Clone repo, orient, create this progress file.
2. ☐ Manually review the send-widget/throughput diff for correctness
   (signatures, call sites, obvious logic bugs) since it's unverified.
3. ☐ Cross-check `ARCHITECTURE.md` Appendix B change log is consistent with
   what's actually in the tree; add an entry if the send-widget work isn't
   logged there yet.
4. ☐ Report findings + next steps.

Checkpoints will be appended below as each numbered step finishes, and I'll
commit locally after each one.

---

## Checkpoint 1 (same session) — manual review of throughput/pipelining code

Reviewed `block_transfer.dart`'s `fetchFileBlockLevel` pipelining (sliding
`inFlight` window, `topUpPipeline`) and the FIFO request/response matching it
depends on (`engine.dart`'s `_sendBlockRequest` + `_BlockSink`,
`file_send.dart`'s equivalent queue). **Conclusion: correct.** Order is
preserved because both `session.send(frame)` and the matching
queue/`Completer` bookkeeping run synchronously (before any `await`) inside
each `sendRequest` call, so firing several requests before awaiting any of
them still yields responses in send order — no request-ID tagging needed,
matches what the code comments claim.

**Finding worth flagging:** the 2026-07-05 doc says the V2 sync engine's own
`fetchFileBlockLevel` call was left untouched at pipeline depth 1
("left alone here deliberately... if it ever becomes the bottleneck"). The
actual code in this snapshot (`engine.dart:21`, `const int
_syncPipelineDepth = 4;`, used at the needs-queue's fetch call site) has
already gone ahead and done that follow-up — undocumented, and with no
dedicated end-to-end test of the *real* engine needs-queue at depth >1 (only
the primitive itself is tested at depth 3/4, via a fake `sendRequest` in
`block_transfer_test.dart`). By inspection this looks safe (doesn't touch
`localSha`/version-vector paths, FIFO preserved), but it's a change to the
core sync engine's wire scheduling that the project's own hard constraint
(Roadmap.md §0) says should get extra scrutiny.

**Action taken:** documented this gap rather than silently leaving it — added
a 2026-07-09 `ARCHITECTURE.md` Appendix B changelog entry and a note under
Roadmap.md Phase 3, both recommending a real `flutter analyze`/`flutter
test`/`flutter build` pass plus a dedicated pipelined-needs-queue regression
test before this is fully trusted. Did not change any source logic — this
was a documentation/traceability fix only.

**Files touched this checkpoint:** `ARCHITECTURE.md`, `Roadmap.md`,
`PROGRESS.md`.

**Committed:** yes (see git log).

---

## Next up

- ☐ Optionally review the compact send-widget window-lifecycle code
  (`send_widget_screen.dart`, `tray.dart`'s bounds-suppression flag) for the
  same kind of by-inspection correctness pass.
- ☐ If you have a machine with the Flutter SDK, run `_run_analyze.bat` and
  `_run_test.bat` (ideally add a depth>1 needs-queue regression test first)
  and report back — I can't run these myself in this sandbox.
- ☐ Waiting on you for: whether to keep reviewing, start a new feature, or
  push these doc fixes (I can't push to GitHub myself — no credentials for
  `johnchk250/Conduit`; let me know if you want a token added, or I can hand
  you a patch/diff instead).
