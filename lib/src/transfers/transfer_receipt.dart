import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqflite_common/sqlite_api.dart' as sqf;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../storage/db_factory.dart';

enum TransferKind { adHoc, folderSync }

enum TransferDirection { incoming, outgoing }

enum TransferStatus {
  offered,
  transferring,
  awaitingPeerConfirmation,
  completed,
  completedUnconfirmed,
  rejected,
  cancelled,
  interrupted,
  failed,
  deferred,
}

enum TransferConfirmation {
  receiverConfirmed,
  localVerified,
  senderServed,
  unsupportedByPeer,
}

enum TransferFailureCode {
  noDestination,
  permissionLost,
  hashMismatch,
  sourceMissing,
  cancelledBySender,
  cancelledByReceiver,
  sessionLost,
  bluetoothSizeLimit,
  writeFailed,
  unsupported,
  unknown,
}

class TransferReceipt {
  const TransferReceipt({
    required this.receiptId,
    required this.correlationId,
    required this.kind,
    required this.direction,
    required this.peerId,
    required this.peerNameSnapshot,
    this.pairId,
    required this.displayName,
    required this.sizeBytes,
    required this.startedAt,
    this.completedAt,
    required this.status,
    required this.confirmation,
    this.failureCode,
    this.localDestinationAvailable = false,
  });

  final String receiptId;
  final String correlationId;
  final TransferKind kind;
  final TransferDirection direction;
  final String peerId;
  final String peerNameSnapshot;
  final String? pairId;
  final String displayName;
  final int sizeBytes;
  final DateTime startedAt;
  final DateTime? completedAt;
  final TransferStatus status;
  final TransferConfirmation confirmation;
  final TransferFailureCode? failureCode;
  final bool localDestinationAvailable;

  TransferReceipt copyWith({
    DateTime? completedAt,
    TransferStatus? status,
    TransferConfirmation? confirmation,
    TransferFailureCode? failureCode,
    bool? localDestinationAvailable,
  }) =>
      TransferReceipt(
        receiptId: receiptId,
        correlationId: correlationId,
        kind: kind,
        direction: direction,
        peerId: peerId,
        peerNameSnapshot: peerNameSnapshot,
        pairId: pairId,
        displayName: displayName,
        sizeBytes: sizeBytes,
        startedAt: startedAt,
        completedAt: completedAt ?? this.completedAt,
        status: status ?? this.status,
        confirmation: confirmation ?? this.confirmation,
        failureCode: failureCode ?? this.failureCode,
        localDestinationAvailable:
            localDestinationAvailable ?? this.localDestinationAvailable,
      );
}

class TransferReceiptRepository {
  TransferReceiptRepository._(this._db);

  final sqf.Database _db;
  final _changes = StreamController<void>.broadcast();

  Stream<void> get changes => _changes.stream;

  static Future<TransferReceiptRepository> open(Directory stateDir) async {
    DbFactory.init();
    final path = p.join(stateDir.path, 'transfer_history.db');
    final db = await databaseFactory.openDatabase(
      path,
      options: sqf.OpenDatabaseOptions(
        version: 1,
        onCreate: (database, _) async {
          await database.execute('''
CREATE TABLE receipts (
  receipt_id TEXT PRIMARY KEY,
  correlation_id TEXT NOT NULL,
  kind TEXT NOT NULL,
  direction TEXT NOT NULL,
  peer_id TEXT NOT NULL,
  peer_name TEXT NOT NULL,
  pair_id TEXT,
  display_name TEXT NOT NULL,
  size_bytes INTEGER NOT NULL,
  started_at INTEGER NOT NULL,
  completed_at INTEGER,
  status TEXT NOT NULL,
  confirmation TEXT NOT NULL,
  failure_code TEXT,
  local_destination_available INTEGER NOT NULL DEFAULT 0
)''');
          await database.execute(
              'CREATE INDEX receipt_time_index ON receipts(started_at DESC)');
          await database.execute(
              'CREATE INDEX receipt_peer_index ON receipts(peer_id, started_at DESC)');
          await database.execute(
              'CREATE INDEX receipt_pair_index ON receipts(pair_id, started_at DESC)');
        },
      ),
    );
    final repository = TransferReceiptRepository._(db);
    await repository.prune();
    return repository;
  }

  Future<void> upsert(TransferReceipt receipt) async {
    await _db.insert(
      'receipts',
      _toRow(receipt),
      conflictAlgorithm: sqf.ConflictAlgorithm.replace,
    );
    _changes.add(null);
  }

  Future<TransferReceipt?> byCorrelation(
    String correlationId, {
    TransferDirection? direction,
  }) async {
    final rows = await _db.query(
      'receipts',
      where: direction == null
          ? 'correlation_id = ?'
          : 'correlation_id = ? AND direction = ?',
      whereArgs: [
        correlationId,
        if (direction != null) direction.name,
      ],
      orderBy: 'started_at DESC',
      limit: 1,
    );
    return rows.isEmpty ? null : _fromRow(rows.first);
  }

  Future<List<TransferReceipt>> recent({int limit = 100}) =>
      _query(orderBy: 'started_at DESC', limit: limit);

  Future<List<TransferReceipt>> forPeer(String peerId, {int limit = 100}) =>
      _query(
        where: 'peer_id = ?',
        whereArgs: [peerId],
        orderBy: 'started_at DESC',
        limit: limit,
      );

  Future<List<TransferReceipt>> forPair(String pairId, {int limit = 100}) =>
      _query(
        where: 'pair_id = ?',
        whereArgs: [pairId],
        orderBy: 'started_at DESC',
        limit: limit,
      );

  Future<void> deleteReceipt(String receiptId) async {
    await _db
        .delete('receipts', where: 'receipt_id = ?', whereArgs: [receiptId]);
    _changes.add(null);
  }

  Future<void> deleteByPeer(String peerId) async {
    await _db.delete('receipts', where: 'peer_id = ?', whereArgs: [peerId]);
    _changes.add(null);
  }

  Future<void> clear() async {
    await _db.delete('receipts');
    _changes.add(null);
  }

  Future<void> prune({
    DateTime? now,
    Duration retention = const Duration(days: 30),
    int maximumRows = 1000,
  }) async {
    final cutoff = (now ?? DateTime.now())
        .toUtc()
        .subtract(retention)
        .millisecondsSinceEpoch;
    await _db.delete('receipts', where: 'started_at < ?', whereArgs: [cutoff]);
    await _db.rawDelete('''
DELETE FROM receipts
WHERE receipt_id NOT IN (
  SELECT receipt_id FROM receipts ORDER BY started_at DESC LIMIT ?
)''', [maximumRows]);
  }

  Future<void> close() async {
    await _changes.close();
    await _db.close();
  }

  Future<List<TransferReceipt>> _query({
    String? where,
    List<Object?>? whereArgs,
    String? orderBy,
    int? limit,
  }) async {
    final rows = await _db.query(
      'receipts',
      where: where,
      whereArgs: whereArgs,
      orderBy: orderBy,
      limit: limit,
    );
    return rows.map(_fromRow).toList(growable: false);
  }

  static Map<String, Object?> _toRow(TransferReceipt receipt) => {
        'receipt_id': receipt.receiptId,
        'correlation_id': receipt.correlationId,
        'kind': receipt.kind.name,
        'direction': receipt.direction.name,
        'peer_id': receipt.peerId,
        'peer_name': receipt.peerNameSnapshot,
        'pair_id': receipt.pairId,
        'display_name': receipt.displayName,
        'size_bytes': receipt.sizeBytes,
        'started_at': receipt.startedAt.toUtc().millisecondsSinceEpoch,
        'completed_at': receipt.completedAt?.toUtc().millisecondsSinceEpoch,
        'status': receipt.status.name,
        'confirmation': receipt.confirmation.name,
        'failure_code': receipt.failureCode?.name,
        'local_destination_available':
            receipt.localDestinationAvailable ? 1 : 0,
      };

  static TransferReceipt _fromRow(Map<String, Object?> row) {
    T parse<T extends Enum>(List<T> values, Object? raw, T fallback) =>
        values.where((value) => value.name == raw).firstOrNull ?? fallback;
    final failureRaw = row['failure_code'];
    return TransferReceipt(
      receiptId: row['receipt_id'] as String,
      correlationId: row['correlation_id'] as String,
      kind: parse(TransferKind.values, row['kind'], TransferKind.adHoc),
      direction: parse(TransferDirection.values, row['direction'],
          TransferDirection.incoming),
      peerId: row['peer_id'] as String,
      peerNameSnapshot: row['peer_name'] as String,
      pairId: row['pair_id'] as String?,
      displayName: row['display_name'] as String,
      sizeBytes: (row['size_bytes'] as num).toInt(),
      startedAt: DateTime.fromMillisecondsSinceEpoch(
          (row['started_at'] as num).toInt(),
          isUtc: true),
      completedAt: row['completed_at'] == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(
              (row['completed_at'] as num).toInt(),
              isUtc: true),
      status:
          parse(TransferStatus.values, row['status'], TransferStatus.failed),
      confirmation: parse(
        TransferConfirmation.values,
        row['confirmation'],
        TransferConfirmation.unsupportedByPeer,
      ),
      failureCode: failureRaw == null
          ? null
          : parse(TransferFailureCode.values, failureRaw,
              TransferFailureCode.unknown),
      localDestinationAvailable:
          (row['local_destination_available'] as num).toInt() == 1,
    );
  }
}
