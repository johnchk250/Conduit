import 'package:flutter_test/flutter_test.dart';

import 'package:conduit/src/sync/ignore_rules.dart';

void main() {
  group('matchesIgnoreRule — globs', () {
    test('"node_modules/**" matches anything under that literal folder', () {
      expect(
        matchesIgnoreRule('node_modules/foo.js',
            sizeBytes: 10, globs: ['node_modules/**']),
        isTrue,
      );
      expect(
        matchesIgnoreRule('node_modules/a/b/c.js',
            sizeBytes: 10, globs: ['node_modules/**']),
        isTrue,
      );
    });

    test('"node_modules/**" does NOT match a differently-named or nested '
        'folder that merely contains the substring', () {
      expect(
        matchesIgnoreRule('src/node_modules/foo.js',
            sizeBytes: 10, globs: ['node_modules/**']),
        isFalse,
      );
      expect(
        matchesIgnoreRule('othernode_modules/foo.js',
            sizeBytes: 10, globs: ['node_modules/**']),
        isFalse,
      );
    });

    test('"*.tmp" (no slash) matches at any depth via basename fallback',
        () {
      expect(matchesIgnoreRule('file.tmp', sizeBytes: 1, globs: ['*.tmp']),
          isTrue);
      expect(
          matchesIgnoreRule('sub/dir/file.tmp',
              sizeBytes: 1, globs: ['*.tmp']),
          isTrue);
      expect(matchesIgnoreRule('file.tmpx', sizeBytes: 1, globs: ['*.tmp']),
          isFalse);
    });

    test('glob matching is case-sensitive', () {
      expect(matchesIgnoreRule('file.TMP', sizeBytes: 1, globs: ['*.tmp']),
          isFalse);
    });

    test('"?" matches exactly one non-slash character', () {
      expect(matchesIgnoreRule('abc.txt', sizeBytes: 1, globs: ['a?c.txt']),
          isTrue);
      expect(matchesIgnoreRule('ac.txt', sizeBytes: 1, globs: ['a?c.txt']),
          isFalse);
      expect(
          matchesIgnoreRule('a/c.txt', sizeBytes: 1, globs: ['a?c.txt']),
          isFalse,
          reason: '? must not match a path separator');
    });

    test('a single "*" does not cross a "/" (one path segment only)', () {
      expect(
          matchesIgnoreRule('Screenshots/img.png',
              sizeBytes: 1, globs: ['Screenshots/*']),
          isTrue);
      expect(
          matchesIgnoreRule('Screenshots/sub/img.png',
              sizeBytes: 1, globs: ['Screenshots/*']),
          isFalse);
    });

    test('known documented limitation: a leading "**/ " pattern does not '
        'also match at the root (unlike full gitignore semantics)', () {
      expect(
          matchesIgnoreRule('a/b/c.log',
              sizeBytes: 1, globs: ['**/*.log']),
          isTrue);
      expect(
          matchesIgnoreRule('c.log', sizeBytes: 1, globs: ['**/*.log']),
          isFalse,
          reason: 'documented limitation — see ignore_rules.dart doc '
              'comment; not a bug');
    });

    test('backslash path separators in the candidate path are normalized',
        () {
      expect(
        matchesIgnoreRule(r'node_modules\foo.js',
            sizeBytes: 1, globs: ['node_modules/**']),
        isTrue,
      );
    });

    test('empty pattern strings are ignored, not treated as match-all', () {
      expect(matchesIgnoreRule('anything.txt', sizeBytes: 1, globs: ['']),
          isFalse);
    });
  });

  group('matchesIgnoreRule — extensions', () {
    test('matches by suffix, case-insensitively', () {
      expect(
          matchesIgnoreRule('a.log',
              sizeBytes: 1, extensions: ['.log']),
          isTrue);
      expect(
          matchesIgnoreRule('a.LOG',
              sizeBytes: 1, extensions: ['.log']),
          isTrue);
      expect(
          matchesIgnoreRule('a.logx',
              sizeBytes: 1, extensions: ['.log']),
          isFalse);
    });

    test('matches at any depth (suffix match, not anchored to a segment)',
        () {
      expect(
          matchesIgnoreRule('sub/dir/a.log',
              sizeBytes: 1, extensions: ['.log']),
          isTrue);
    });
  });

  group('matchesIgnoreRule — max file size', () {
    test('files at or under the cap are not matched', () {
      expect(
          matchesIgnoreRule('a.bin',
              sizeBytes: 100, maxFileSizeBytes: 100),
          isFalse);
      expect(
          matchesIgnoreRule('a.bin',
              sizeBytes: 99, maxFileSizeBytes: 100),
          isFalse);
    });

    test('files over the cap are matched', () {
      expect(
          matchesIgnoreRule('a.bin',
              sizeBytes: 101, maxFileSizeBytes: 100),
          isTrue);
    });

    test('null cap (the default) never matches on size', () {
      expect(
          matchesIgnoreRule('a.bin',
              sizeBytes: 1 << 40), // absurdly large
          isFalse);
    });
  });

  group('matchesIgnoreRule — no rules configured (default)', () {
    test('never matches anything — every existing scan() caller that '
        'passes no ignore params must behave byte-for-byte unchanged', () {
      expect(matchesIgnoreRule('anything/at/all.txt', sizeBytes: 999999999),
          isFalse);
    });
  });

  group('matchesIgnoreRule — rules combine (OR, not AND)', () {
    test('a match on any one of globs/extensions/size is enough', () {
      expect(
        matchesIgnoreRule(
          'keep.txt',
          sizeBytes: 1,
          globs: ['does-not-match/**'],
          extensions: ['.log'],
          maxFileSizeBytes: 100,
        ),
        isFalse,
      );
      expect(
        matchesIgnoreRule(
          'keep.txt',
          sizeBytes: 1,
          globs: ['does-not-match/**'],
          extensions: ['.log'],
          maxFileSizeBytes: 0, // any size > 0 exceeds this
        ),
        isTrue,
      );
    });
  });
}
