import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:conduit/src/transfers/transfer_receipt.dart';

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('receipt_repo_test_');
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  TransferReceipt receipt(String id, DateTime startedAt) => TransferReceipt(
        receiptId: id,
        correlationId: 'corr-$id',
        kind: TransferKind.adHoc,
        direction: TransferDirection.outgoing,
        peerId: 'peer',
        peerNameSnapshot: 'Peer',
        pairId: 'pair',
        displayName: 'file.txt',
        sizeBytes: 12,
        startedAt: startedAt,
        status: TransferStatus.offered,
        confirmation: TransferConfirmation.unsupportedByPeer,
      );

  test('insert, update, reopen, and query by peer/pair', () async {
    var repo = await TransferReceiptRepository.open(root);
    final original = receipt('one', DateTime.utc(2026, 7, 17));
    await repo.upsert(original);
    await repo.upsert(original.copyWith(
      status: TransferStatus.completedUnconfirmed,
      completedAt: DateTime.utc(2026, 7, 17, 1),
    ));
    expect((await repo.forPeer('peer')).single.status,
        TransferStatus.completedUnconfirmed);
    expect(await repo.forPair('pair'), hasLength(1));
    await repo.close();

    repo = await TransferReceiptRepository.open(root);
    expect(await repo.recent(), hasLength(1));
    await repo.close();
  });

  test('prune applies age retention and maximum row count', () async {
    final repo = await TransferReceiptRepository.open(root);
    await repo.upsert(receipt('old', DateTime.utc(2026, 1, 1)));
    for (var i = 0; i < 5; i++) {
      await repo.upsert(receipt('new-$i', DateTime.utc(2026, 7, 17, i)));
    }
    await repo.prune(
      now: DateTime.utc(2026, 7, 17),
      maximumRows: 3,
    );
    final rows = await repo.recent();
    expect(rows, hasLength(3));
    expect(rows.any((row) => row.receiptId == 'old'), isFalse);
    await repo.close();
  });
}
