/// Roadmap Phase 6.2 — ignore rules (glob / extension / size).
///
/// A small, self-contained pattern matcher — deliberately NOT the `glob`
/// pub package. This environment has no Flutter/Dart SDK and no pub.dev
/// network access to fetch or verify a new dependency against, so rather
/// than add one on faith this implements just the subset of glob syntax
/// ignore rules actually need. See PROGRESS.md 2026-07-11 for the full
/// reasoning. Swapping in the real `glob` package later, if wanted, is a
/// drop-in replacement for [matchesIgnoreRule]'s glob branch only — nothing
/// else in the scanner needs to change.
///
/// Supported glob syntax:
///   `*`  — any run of characters EXCEPT `/` (one path segment)
///   `**` — any run of characters INCLUDING `/` (any depth)
///   `?`  — exactly one character except `/`
///   anything else — matched literally
/// A pattern containing no `/` is also matched against just the file's
/// basename, at any depth — e.g. `*.tmp` matches both `x.tmp` and
/// `sub/dir/x.tmp`. A pattern that DOES contain `/` is matched only against
/// the full relative path (e.g. `**/x.tmp` matches `sub/x.tmp` but, as a
/// known/documented limitation, does not also match a root-level `x.tmp` —
/// full gitignore-style semantics were judged not worth the extra
/// complexity for the documented use cases (`node_modules/**`, `*.tmp`)).
library;

/// True if [relPath] (size [sizeBytes]) matches any ignore rule.
///
/// Used by [IndexScanner.scan] to skip a file BEFORE it's ever hashed or
/// passed to [IndexDb.upsertLocal] — an ignored file never enters the Index
/// DB, never gets a version vector, never enters the needs-queue. Same
/// "never-indexed" shape `.syncstate`/`.syncversions` already use via
/// `_isInternalArtefact`, just user-configurable.
///
/// Retroactive-ignore semantics (confirmed with the user 2026-07-11): a
/// previously-synced file that starts matching a rule is FROZEN, not
/// deleted — this function only decides "should the scanner skip
/// re-hashing/re-upserting this path"; it is the scanner's job (not this
/// function's) to still add the path to `seenPaths` so the tombstone sweep
/// doesn't mistake "now ignored" for "locally deleted" and propagate a
/// delete to the peer.
bool matchesIgnoreRule(
  String relPath, {
  required int sizeBytes,
  List<String> globs = const [],
  List<String> extensions = const [],
  int? maxFileSizeBytes,
}) {
  if (maxFileSizeBytes != null && sizeBytes > maxFileSizeBytes) return true;

  final norm = relPath.replaceAll('\\', '/');

  if (extensions.isNotEmpty) {
    final lower = norm.toLowerCase();
    for (final ext in extensions) {
      if (ext.isEmpty) continue;
      if (lower.endsWith(ext.toLowerCase())) return true;
    }
  }

  for (final pattern in globs) {
    if (pattern.isEmpty) continue;
    if (_matchesGlob(pattern, norm)) return true;
  }

  return false;
}

bool _matchesGlob(String pattern, String path) {
  final normPattern = pattern.replaceAll('\\', '/');
  final regex = RegExp('^${_globToRegexBody(normPattern)}\$');
  if (regex.hasMatch(path)) return true;
  // No '/' in the pattern → also try matching just the basename, at any
  // depth (see class doc for why: this is what makes `*.tmp` work anywhere
  // in the tree instead of only at the folder root).
  if (!normPattern.contains('/')) {
    final slash = path.lastIndexOf('/');
    final basename = slash == -1 ? path : path.substring(slash + 1);
    if (regex.hasMatch(basename)) return true;
  }
  return false;
}

/// Translates glob syntax into a regex body (no anchors — caller adds
/// `^`/`$`). Every character is either a glob metacharacter handled
/// explicitly below or is regex-escaped individually, so nothing from the
/// user's pattern can accidentally inject unintended regex syntax.
String _globToRegexBody(String pattern) {
  final buf = StringBuffer();
  var i = 0;
  while (i < pattern.length) {
    final c = pattern[i];
    if (c == '*') {
      if (i + 1 < pattern.length && pattern[i + 1] == '*') {
        buf.write('.*'); // '**' — any run of chars, including '/'
        i += 2;
      } else {
        buf.write('[^/]*'); // '*' — any run of chars except '/'
        i += 1;
      }
    } else if (c == '?') {
      buf.write('[^/]');
      i += 1;
    } else {
      buf.write(RegExp.escape(c));
      i += 1;
    }
  }
  return buf.toString();
}
