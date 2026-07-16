import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../controllers/app_controllers.dart';
import '../transfers/transfer_receipt.dart';

class TransferHistoryScreen extends StatefulWidget {
  const TransferHistoryScreen({super.key, this.peerId, this.pairId});

  final String? peerId;
  final String? pairId;

  @override
  State<TransferHistoryScreen> createState() => _TransferHistoryScreenState();
}

class _TransferHistoryScreenState extends State<TransferHistoryScreen> {
  List<TransferReceipt>? _receipts;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _receipts = null;
      _error = null;
    });
    try {
      final controller = context.read<TransferController>();
      final value = widget.peerId != null
          ? await controller.receiptsForPeer(widget.peerId!)
          : widget.pairId != null
              ? await controller.receiptsForPair(widget.pairId!)
              : await controller.recentReceipts();
      if (mounted) setState(() => _receipts = value);
    } catch (error) {
      if (mounted) setState(() => _error = error);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Transfer receipts'),
        actions: [
          IconButton(
            tooltip: 'Clear history',
            onPressed: _receipts?.isNotEmpty == true ? _clearAll : null,
            icon: const Icon(Icons.delete_sweep_outlined),
          ),
        ],
      ),
      body: _body(),
    );
  }

  Widget _body() {
    if (_error != null) {
      return Center(child: Text('Could not load receipts: $_error'));
    }
    final receipts = _receipts;
    if (receipts == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (receipts.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'No transfer receipts yet. Completed, interrupted, cancelled, and deferred transfers will appear here.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        padding: const EdgeInsets.all(12),
        itemCount: receipts.length,
        separatorBuilder: (_, __) => const Divider(height: 1),
        itemBuilder: (context, index) {
          final receipt = receipts[index];
          return Dismissible(
            key: ValueKey(receipt.receiptId),
            direction: DismissDirection.endToStart,
            background: Container(
              color: Theme.of(context).colorScheme.errorContainer,
              alignment: Alignment.centerRight,
              padding: const EdgeInsets.only(right: 20),
              child: const Icon(Icons.delete_outline),
            ),
            onDismissed: (_) async {
              await context
                  .read<TransferController>()
                  .clearReceipt(receipt.receiptId);
              await _load();
            },
            child: ListTile(
              leading: Icon(receipt.direction == TransferDirection.incoming
                  ? Icons.south_west_rounded
                  : Icons.north_east_rounded),
              title: Text(receipt.displayName),
              subtitle: Text(
                '${receipt.peerNameSnapshot} · ${_bytes(receipt.sizeBytes)} · ${_status(receipt)}\n'
                '${receipt.startedAt.toLocal()}'
                '${receipt.pairId == null ? '' : ' · Folder sync'}',
              ),
              isThreeLine: true,
            ),
          );
        },
      ),
    );
  }

  Future<void> _clearAll() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Clear transfer history?'),
        content: const Text(
          'This removes local receipt metadata only. It does not delete transferred files.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await context.read<TransferController>().clearHistory();
    await _load();
  }

  String _status(TransferReceipt receipt) {
    if (receipt.status == TransferStatus.completed &&
        receipt.confirmation == TransferConfirmation.receiverConfirmed) {
      return 'Delivered';
    }
    if (receipt.status == TransferStatus.completedUnconfirmed) {
      return 'Sent, confirmation unavailable';
    }
    return receipt.status.name
        .replaceAllMapped(RegExp(r'([A-Z])'), (match) => ' ${match.group(1)}')
        .toLowerCase();
  }

  String _bytes(int value) {
    if (value >= 1024 * 1024) {
      return '${(value / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    if (value >= 1024) return '${(value / 1024).toStringAsFixed(1)} KB';
    return '$value B';
  }
}
