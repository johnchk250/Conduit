import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:conduit/src/sync/manifest.dart';

void main() {
  late Directory root;
  const fs = LocalFileSystemAccess();

  setUp(() async {
    root = await Directory.systemTemp.createTemp('local_fs_access_test_');
  });

  tearDown(() async {
    if (await root.exists()) {
      await root.delete(recursive: true);
    }
  });

  test('moveToVault moves the file — the original path no longer exists',
      () async {
    final src = File(p.join(root.path, 'a.txt'));
    await src.writeAsString('hello');

    await fs.moveToVault(root.path, 'a.txt');

    expect(await src.exists(), isFalse);
  });

  test(
      'moveToVault returns a path RELATIVE to rootPath — regression test '
      'for the pre-Phase-6.4 bug where Local returned an absolute path '
      'while the Android SAF implementation returned a relative one '
      '(see PROGRESS.md 2026-07-11)', () async {
    final src = File(p.join(root.path, 'a.txt'));
    await src.writeAsString('hello');

    final vaultPath = await fs.moveToVault(root.path, 'a.txt');

    expect(p.isRelative(vaultPath), isTrue,
        reason: 'must not be an absolute path');
    expect(vaultPath, isNot(contains(root.path)),
        reason: 'must not have rootPath baked into it');
  });

  test('the returned relative path, joined back onto rootPath, contains '
      'the original bytes', () async {
    final src = File(p.join(root.path, 'a.txt'));
    await src.writeAsBytes([1, 2, 3, 4, 5]);

    final vaultPath = await fs.moveToVault(root.path, 'a.txt');
    final vaulted = File(p.join(root.path, vaultPath));

    expect(await vaulted.exists(), isTrue);
    expect(await vaulted.readAsBytes(), [1, 2, 3, 4, 5]);
  });

  test('the returned path lives under .syncversions/ and keeps the '
      'original extension', () async {
    final src = File(p.join(root.path, 'report.docx'));
    await src.writeAsString('doc bytes');

    final vaultPath = await fs.moveToVault(root.path, 'report.docx');

    expect(vaultPath, startsWith('.syncversions/'));
    expect(vaultPath, endsWith('.docx'));
    expect(p.basename(vaultPath), startsWith('report.'));
  });

  test('a top-level file (no directory component) produces a clean path '
      'with no stray "." segment', () async {
    final src = File(p.join(root.path, 'a.txt'));
    await src.writeAsString('hello');

    final vaultPath = await fs.moveToVault(root.path, 'a.txt');

    expect(vaultPath, equals('.syncversions/${p.basename(vaultPath)}'));
    expect(vaultPath, isNot(contains('/./')));
    expect(vaultPath, isNot(contains('//')));
  });

  test('a nested file preserves its subdirectory under .syncversions/',
      () async {
    final dir = Directory(p.join(root.path, 'docs', 'sub'));
    await dir.create(recursive: true);
    final src = File(p.join(dir.path, 'report.docx'));
    await src.writeAsString('doc bytes');

    final vaultPath = await fs.moveToVault(root.path, 'docs/sub/report.docx');

    expect(vaultPath, startsWith('.syncversions/docs/sub/'));
  });

  test('two vault calls for the same relPath produce two distinct '
      'destinations (both readable), not a silent overwrite', () async {
    final src = File(p.join(root.path, 'a.txt'));
    await src.writeAsString('version 1');
    final vaultPath1 = await fs.moveToVault(root.path, 'a.txt');

    // The destination name includes a timestamp — force it to actually
    // differ rather than gambling on two awaited I/O calls naturally
    // spanning a clock tick. Without this, the test would be flaky
    // (and, worse, on a collision the second rename could silently
    // overwrite version 1 depending on the OS's rename-onto-existing-file
    // semantics) — can't execute this suite here to discover that
    // empirically, so made deterministic instead.
    await Future.delayed(const Duration(milliseconds: 5));

    await src.writeAsString('version 2'); // simulate a later re-sync
    final vaultPath2 = await fs.moveToVault(root.path, 'a.txt');

    expect(vaultPath1, isNot(equals(vaultPath2)));
    expect(
        await File(p.join(root.path, vaultPath1)).readAsString(), 'version 1');
    expect(
        await File(p.join(root.path, vaultPath2)).readAsString(), 'version 2');
  });
}
