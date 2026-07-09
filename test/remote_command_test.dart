import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:conduit/src/desktop/commands.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('RemoteCommandExecutor', () {
    final List<MethodCall> methodCalls = [];

    setUp(() {
      methodCalls.clear();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('conduit/remote_keys'),
        (MethodCall methodCall) async {
          methodCalls.add(methodCall);
          return null;
        },
      );
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('conduit/remote_keys'),
        null,
      );
    });

    test('ignores command when disabled', () async {
      var logged = false;
      final executor = RemoteCommandExecutor(
        enabled: false,
        onLog: (msg, {isError = false}) {
          if (msg.contains('disabled')) {
            logged = true;
          }
        },
      );

      final ok = await executor.execute('volume_up');
      expect(ok, isFalse);
      expect(logged, isTrue);
      expect(methodCalls, isEmpty);
    });

    test('rejects command not in allowlist', () async {
      var loggedError = false;
      final executor = RemoteCommandExecutor(
        enabled: true,
        onLog: (msg, {isError = false}) {
          if (isError && msg.contains('not in allowlist')) {
            loggedError = true;
          }
        },
      );

      final ok = await executor.execute('format_c_drive');
      expect(ok, isFalse);
      expect(loggedError, isTrue);
      expect(methodCalls, isEmpty);
    });

    test('executes allowlisted media command via channel', () async {
      final executor = RemoteCommandExecutor(
        enabled: true,
      );

      final ok = await executor.execute('volume_up');
      expect(ok, isTrue);
      expect(methodCalls.length, 1);
      expect(methodCalls.first.method, 'volume_up');
    });
  });
}
