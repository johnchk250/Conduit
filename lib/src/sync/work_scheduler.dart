import 'dart:async';

final heavyWorkScheduler = HeavyWorkScheduler();

/// Prevents several heavy jobs from making the UI, disk cache, and GC compete.
/// A single transfer is never bandwidth-throttled.
class HeavyWorkScheduler {
  final _scanSlots = _AsyncSemaphore(1);
  final _transferSlots = _AsyncSemaphore(2);

  Future<T> runScan<T>(Future<T> Function() work) => _scanSlots.run(work);
  Future<WorkLease> acquireTransfer() => _transferSlots.acquire();
}

class WorkLease {
  WorkLease(this._release);
  final void Function() _release;
  bool _released = false;

  void release() {
    if (_released) return;
    _released = true;
    _release();
  }
}

class _AsyncSemaphore {
  _AsyncSemaphore(this._available);
  int _available;
  final _waiters = <Completer<WorkLease>>[];

  Future<WorkLease> acquire() {
    if (_available > 0) {
      _available--;
      return Future.value(_lease());
    }
    final waiter = Completer<WorkLease>();
    _waiters.add(waiter);
    return waiter.future;
  }

  Future<T> run<T>(Future<T> Function() work) async {
    final lease = await acquire();
    try {
      return await work();
    } finally {
      lease.release();
    }
  }

  WorkLease _lease() => WorkLease(() {
        if (_waiters.isNotEmpty) {
          _waiters.removeAt(0).complete(_lease());
        } else {
          _available++;
        }
      });
}
