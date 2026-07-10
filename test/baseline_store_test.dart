import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vouch/vouch.dart';

import 'helpers.dart';

void main() {
  const model = ModelInfo(id: 'gemma-3-1b-it');
  late Directory tmp;
  late BaselineStore store;

  Baseline sample() => Baseline.fromReport(
    reportOf([caseOf('greets', 'Hello!')], suite: 'chat'),
    model: model,
    createdAt: DateTime.utc(2026, 7, 10),
  );

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('vouch_store_test');
    store = BaselineStore(tmp.path);
  });

  tearDown(() => tmp.deleteSync(recursive: true));

  test('save writes <suiteName>.baseline.json by default', () {
    store.save(sample());
    expect(store.exists('chat'), isTrue);
    expect(store.pathFor('chat'), endsWith('chat.baseline.json'));
    expect(File(store.pathFor('chat')).existsSync(), isTrue);
  });

  test('save honors an explicit name for per-model baselines', () {
    store.save(sample(), name: 'chat-gemma3');
    expect(store.exists('chat-gemma3'), isTrue);
    expect(store.exists('chat'), isFalse);
  });

  test('load round-trips what save wrote', () {
    final baseline = sample();
    store.save(baseline);
    final back = store.load('chat');
    expect(back.toJson(), baseline.toJson());
  });

  test('files are pretty-printed with a trailing newline', () {
    store.save(sample());
    final raw = File(store.pathFor('chat')).readAsStringSync();
    expect(raw, endsWith('\n'));
    expect(raw, contains('\n  "suite": "chat"'));
  });

  test('load of a missing baseline throws a StateError naming it', () {
    expect(
      () => store.load('nope'),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('nope'),
        ),
      ),
    );
  });

  test('loadOrNull of a missing baseline returns null', () {
    expect(store.loadOrNull('nope'), isNull);
  });

  test('a non-object JSON file throws BaselineFormatException', () {
    File(store.pathFor('bad')).writeAsStringSync('[]');
    expect(
      () => store.load('bad'),
      throwsA(isA<BaselineFormatException>()),
    );
  });

  test('invalid UTF-8 bytes throw BaselineFormatException, not a raw '
      'FileSystemException', () {
    // Audit round 2: readAsStringSync leaked FileSystemException on
    // non-UTF-8 bytes instead of the documented exception type.
    File(store.pathFor('binary'))
        .writeAsBytesSync(const [0xFF, 0xFE, 0x00, 0x9C, 0x80]);
    expect(
      () => store.load('binary'),
      throwsA(isA<BaselineFormatException>()),
    );
  });

  test('unparsable file content throws BaselineFormatException, '
      'not a raw FormatException', () {
    for (final content in [
      '', // truncated to nothing
      '{"formatVersion": 1} trailing garbage',
      '<<<<<<< HEAD\n{}\n=======\n{}\n>>>>>>> theirs', // merge conflict
    ]) {
      File(store.pathFor('corrupt')).writeAsStringSync(content);
      expect(
        () => store.load('corrupt'),
        throwsA(isA<BaselineFormatException>()),
        reason: 'content: $content',
      );
    }
  });

  test('save creates the directory when absent', () {
    final nested = BaselineStore('${tmp.path}/a/b');
    nested.save(sample());
    expect(nested.exists('chat'), isTrue);
  });

  test('a name with a path separator throws instead of escaping the '
      'directory', () {
    final baseline = Baseline.fromReport(
      reportOf([caseOf('a', 'x')], suite: 'chat/v1'),
      model: model,
    );
    expect(() => store.save(baseline), throwsA(isA<ArgumentError>()));
    expect(() => store.load('../sneaky'), throwsA(isA<ArgumentError>()));
    // An explicit safe name keeps an awkward suite name usable.
    store.save(baseline, name: 'chat-v1');
    expect(store.exists('chat-v1'), isTrue);
  });

  test('a non-JSON value in ModelInfo.extra fails save with a clear '
      'ArgumentError, not a raw encoder crash', () {
    final baseline = Baseline.fromReport(
      reportOf([caseOf('a', 'x')], suite: 'chat'),
      model: ModelInfo(id: 'm', extra: {'bad': Object()}),
    );
    expect(
      () => store.save(baseline),
      throwsA(
        isA<ArgumentError>().having(
          (e) => e.message,
          'message',
          contains('extra'),
        ),
      ),
    );
  });
}
