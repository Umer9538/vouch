import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:llm_replay_eval/llm_replay_eval.dart';
import 'package:vouch/vouch.dart';

import 'helpers.dart';

void main() {
  const model = ModelInfo(id: 'gemma-3-1b-it', quantization: 'q4');

  group('Baseline.fromReport', () {
    test('freezes every case, check, output and verdict', () {
      final report = reportOf([
        caseOf('greets', 'Hello!'),
        CaseResult(
          name: 'scores',
          output: '{"ok":true}',
          results: [
            const EvalResult(
              criterion: 'judge',
              passed: true,
              score: 0.9,
              detail: 'solid',
            ),
            EvalResult.boolean('json', passed: true),
          ],
        ),
        caseOf('flaky', 'nope', passed: false),
      ]);

      final baseline = Baseline.fromReport(report, model: model);

      expect(baseline.suiteName, 'suite');
      expect(baseline.model.label, model.label);
      expect(baseline.entries, hasLength(3));

      final scores = baseline.entryFor('scores')!;
      expect(scores.passed, isTrue);
      expect(scores.output, '{"ok":true}');
      expect(scores.checkFor('judge')!.score, 0.9);
      expect(scores.checkFor('judge')!.detail, 'solid');
      expect(scores.checkFor('json')!.score, 1.0);
      expect(scores.checkFor('absent'), isNull);

      expect(baseline.entryFor('flaky')!.passed, isFalse);
      expect(baseline.entryFor('missing'), isNull);
    });

    test('a boolean NaN-score check freezes with no score', () {
      final report = reportOf([
        CaseResult(
          name: 'nan',
          output: 'x',
          results: [const EvalResult(criterion: 'c', passed: true)],
        ),
      ]);
      final baseline = Baseline.fromReport(report, model: model);
      expect(baseline.entryFor('nan')!.checkFor('c')!.score, isNull);
    });

    test('duplicate case names throw ArgumentError', () {
      final report = reportOf([caseOf('dup', 'a'), caseOf('dup', 'b')]);
      expect(
        () => Baseline.fromReport(report, model: model),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            contains('dup'),
          ),
        ),
      );
    });
  });

  group('Baseline JSON', () {
    test('survives an encode/decode round-trip byte-for-byte', () {
      final baseline = Baseline.fromReport(
        reportOf([
          caseOf('greets', 'Hello!\nSecond line'),
          caseOf('fails', 'bad', passed: false),
        ]),
        model: model,
        createdAt: DateTime.utc(2026, 7, 10, 12, 30),
      );

      final wire = jsonEncode(baseline.toJson());
      final back = Baseline.fromJson(jsonDecode(wire) as Map<String, Object?>);

      expect(back.toJson(), baseline.toJson());
      expect(back.createdAt, baseline.createdAt);
      expect(back.model.label, model.label);
    });

    test('unsupported format version throws BaselineFormatException', () {
      expect(
        () => Baseline.fromJson(const {'formatVersion': 999}),
        throwsA(isA<BaselineFormatException>()),
      );
    });

    test('missing format version throws BaselineFormatException', () {
      expect(
        () => Baseline.fromJson(const {'suite': 's'}),
        throwsA(isA<BaselineFormatException>()),
      );
    });

    test('malformed fields throw BaselineFormatException', () {
      expect(
        () => Baseline.fromJson(const {
          'formatVersion': 1,
          'suite': 's',
          'model': {'id': 'm'},
          'createdAt': 42,
          'entries': [],
        }),
        throwsA(isA<BaselineFormatException>()),
      );
    });

    test('bad model id surfaces as BaselineFormatException', () {
      expect(
        () => Baseline.fromJson(const {
          'formatVersion': 1,
          'suite': 's',
          'model': {'notId': true},
          'createdAt': '2026-07-10T00:00:00.000Z',
          'entries': [],
        }),
        throwsA(isA<BaselineFormatException>()),
      );
    });

    test('unparsable createdAt surfaces as BaselineFormatException', () {
      expect(
        () => Baseline.fromJson(const {
          'formatVersion': 1,
          'suite': 's',
          'model': {'id': 'm'},
          'createdAt': 'not a date',
          'entries': [],
        }),
        throwsA(isA<BaselineFormatException>()),
      );
    });

    test('createdAt is serialized in UTC and preserves the instant', () {
      final local = DateTime(2026, 7, 10, 17, 30); // local wall-clock time
      final baseline = Baseline.fromReport(
        reportOf([caseOf('a', 'x')]),
        model: model,
        createdAt: local,
      );
      final wire = baseline.toJson()['createdAt'] as String;
      expect(wire, endsWith('Z'));
      final back = Baseline.fromJson(
        jsonDecode(jsonEncode(baseline.toJson())) as Map<String, Object?>,
      );
      expect(back.createdAt.isAtSameMomentAs(local), isTrue);
    });

    test('a non-object item in "entries" throws instead of being skipped', () {
      // Silently dropping a corrupt entry would shrink coverage and let a
      // vanished case pass the gate as CLEAN.
      expect(
        () => Baseline.fromJson(const {
          'formatVersion': 1,
          'suite': 's',
          'model': {'id': 'm'},
          'createdAt': '2026-07-10T00:00:00.000Z',
          'entries': [42],
        }),
        throwsA(isA<BaselineFormatException>()),
      );
    });

    test('non-list "checks" throws instead of being treated as empty', () {
      expect(
        () => Baseline.fromJson(const {
          'formatVersion': 1,
          'suite': 's',
          'model': {'id': 'm'},
          'createdAt': '2026-07-10T00:00:00.000Z',
          'entries': [
            {'name': 'a', 'passed': true, 'output': 'x', 'checks': 'oops'},
          ],
        }),
        throwsA(isA<BaselineFormatException>()),
      );
    });

    test('a non-object item in "checks" throws instead of being skipped', () {
      expect(
        () => Baseline.fromJson(const {
          'formatVersion': 1,
          'suite': 's',
          'model': {'id': 'm'},
          'createdAt': '2026-07-10T00:00:00.000Z',
          'entries': [
            {
              'name': 'a',
              'passed': true,
              'output': 'x',
              'checks': [null],
            },
          ],
        }),
        throwsA(isA<BaselineFormatException>()),
      );
    });

    test('a non-numeric check score throws BaselineFormatException', () {
      expect(
        () => Baseline.fromJson(const {
          'formatVersion': 1,
          'suite': 's',
          'model': {'id': 'm'},
          'createdAt': '2026-07-10T00:00:00.000Z',
          'entries': [
            {
              'name': 'a',
              'passed': true,
              'output': 'x',
              'checks': [
                {'criterion': 'c', 'passed': true, 'score': 'high'},
              ],
            },
          ],
        }),
        throwsA(isA<BaselineFormatException>()),
      );
    });

    test('a non-string check detail throws BaselineFormatException', () {
      expect(
        () => Baseline.fromJson(const {
          'formatVersion': 1,
          'suite': 's',
          'model': {'id': 'm'},
          'createdAt': '2026-07-10T00:00:00.000Z',
          'entries': [
            {
              'name': 'a',
              'passed': true,
              'output': 'x',
              'checks': [
                {'criterion': 'c', 'passed': true, 'detail': 7},
              ],
            },
          ],
        }),
        throwsA(isA<BaselineFormatException>()),
      );
    });

    test('duplicate entry names in a document throw '
        'BaselineFormatException, not ArgumentError', () {
      expect(
        () => Baseline.fromJson(const {
          'formatVersion': 1,
          'suite': 's',
          'model': {'id': 'm'},
          'createdAt': '2026-07-10T00:00:00.000Z',
          'entries': [
            {'name': 'dup', 'passed': true, 'output': 'a', 'checks': []},
            {'name': 'dup', 'passed': true, 'output': 'b', 'checks': []},
          ],
        }),
        throwsA(isA<BaselineFormatException>()),
      );
    });

    test('wrong-typed model fields surface as BaselineFormatException', () {
      expect(
        () => Baseline.fromJson(const {
          'formatVersion': 1,
          'suite': 's',
          'model': {'id': 'm', 'version': 3},
          'createdAt': '2026-07-10T00:00:00.000Z',
          'entries': [],
        }),
        throwsA(isA<BaselineFormatException>()),
      );
    });

    test('malformed entry throws BaselineFormatException', () {
      expect(
        () => Baseline.fromJson(const {
          'formatVersion': 1,
          'suite': 's',
          'model': {'id': 'm'},
          'createdAt': '2026-07-10T00:00:00.000Z',
          'entries': [
            {'name': 'x', 'passed': 'yes', 'output': 'o'},
          ],
        }),
        throwsA(isA<BaselineFormatException>()),
      );
    });
  });
}
