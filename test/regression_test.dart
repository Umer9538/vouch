import 'package:flutter_test/flutter_test.dart';
import 'package:llm_replay_eval/llm_replay_eval.dart';
import 'package:vouch/vouch.dart';

import 'helpers.dart';

void main() {
  const gemma3 = ModelInfo(id: 'gemma-3-1b-it', quantization: 'q4');
  const gemma3n = ModelInfo(id: 'gemma-3n-e2b', quantization: 'q4');

  Baseline baselineOf(List<CaseResult> cases) =>
      Baseline.fromReport(reportOf(cases), model: gemma3,
          createdAt: DateTime.utc(2026, 7, 8));

  group('classification', () {
    test('identical run is fully stable', () {
      final cases = [caseOf('a', 'out-a'), caseOf('b', 'out-b')];
      final diff = compareToBaseline(baselineOf(cases), reportOf(cases));

      expect(diff.findings, isEmpty);
      expect(diff.stableCount, 2);
      expect(diff.totalCompared, 2);
      expect(diff.hasRegressions, isFalse);
      expect(diff.summary(), contains('CLEAN'));
    });

    test('pass → fail is regressed, with the flipped check and detail', () {
      final diff = compareToBaseline(
        baselineOf([
          CaseResult(
            name: 'policy',
            output: '{"refund":true}',
            results: [EvalResult.boolean('json', passed: true)],
          ),
        ]),
        reportOf([
          CaseResult(
            name: 'policy',
            output: 'Sure! Here is some text.',
            results: [
              EvalResult.boolean(
                'json',
                passed: false,
                detail: 'not valid JSON',
              ),
            ],
          ),
        ]),
      );

      expect(diff.hasRegressions, isTrue);
      final f = diff.regressed.single;
      expect(f.caseName, 'policy');
      expect(f.baselinePassed, isTrue);
      expect(f.currentPassed, isFalse);
      expect(f.outputChanged, isTrue);
      final d = f.checkDeltas.single;
      expect(d.criterion, 'json');
      expect(d.baselinePassed, isTrue);
      expect(d.currentPassed, isFalse);
      expect(d.detail, 'not valid JSON');
      expect(diff.summary(), contains('REGRESSED'));
      expect(diff.summary(), contains('policy'));
    });

    test('fail → pass is fixed', () {
      final diff = compareToBaseline(
        baselineOf([caseOf('a', 'bad', passed: false)]),
        reportOf([caseOf('a', 'good')]),
      );
      expect(diff.fixed.single.caseName, 'a');
      expect(diff.hasRegressions, isFalse);
    });

    test('fail → fail is stillFailing and records the output change', () {
      final diff = compareToBaseline(
        baselineOf([caseOf('a', 'bad-1', passed: false)]),
        reportOf([caseOf('a', 'bad-2', passed: false)]),
      );
      final f = diff.stillFailing.single;
      expect(f.outputChanged, isTrue);
      expect(diff.hasRegressions, isFalse);
    });

    test('passing but with different output is drifted', () {
      final diff = compareToBaseline(
        baselineOf([caseOf('a', 'Hello!')]),
        reportOf([caseOf('a', 'Hello there!')]),
      );
      final f = diff.drifted.single;
      expect(f.outputChanged, isTrue);
      expect(f.checkDeltas, isEmpty);
      expect(diff.hasRegressions, isFalse);
    });

    test('case only in current run is added', () {
      final diff = compareToBaseline(
        baselineOf([caseOf('a', 'x')]),
        reportOf([caseOf('a', 'x'), caseOf('new-pass', 'y')]),
      );
      final f = diff.added.single;
      expect(f.caseName, 'new-pass');
      expect(f.currentPassed, isTrue);
      expect(f.baselineOutput, isNull);
      expect(f.outputChanged, isNull);
      expect(diff.addedFailing, isEmpty);
    });

    test('added failing case carries its failing checks', () {
      final diff = compareToBaseline(
        baselineOf([]),
        reportOf([
          CaseResult(
            name: 'new-fail',
            output: 'z',
            results: [
              EvalResult.boolean('ok', passed: true),
              EvalResult.boolean('json', passed: false, detail: 'nope'),
            ],
          ),
        ]),
      );
      final f = diff.addedFailing.single;
      expect(f.checkDeltas.single.criterion, 'json');
      expect(f.checkDeltas.single.detail, 'nope');
    });

    test('case only in baseline is removed', () {
      final diff = compareToBaseline(
        baselineOf([caseOf('gone', 'x')]),
        reportOf([]),
      );
      final f = diff.removed.single;
      expect(f.caseName, 'gone');
      expect(f.baselinePassed, isTrue);
      expect(f.currentOutput, isNull);
    });
  });

  group('scores', () {
    CaseResult judged(String name, double score) => CaseResult(
      name: name,
      output: 'same output',
      results: [
        EvalResult(criterion: 'judge', passed: true, score: score),
      ],
    );

    test('score movement beyond tolerance is drift with a delta', () {
      final diff = compareToBaseline(
        baselineOf([judged('a', 0.90)]),
        reportOf([judged('a', 0.60)]),
        scoreTolerance: 0.1,
      );
      final d = diff.drifted.single.checkDeltas.single;
      expect(d.scoreDelta, closeTo(-0.30, 1e-9));
      expect(d.baselineScore, 0.90);
      expect(d.currentScore, 0.60);
    });

    test('score movement within tolerance is stable', () {
      final diff = compareToBaseline(
        baselineOf([judged('a', 0.90)]),
        reportOf([judged('a', 0.85)]),
        scoreTolerance: 0.1,
      );
      expect(diff.findings, isEmpty);
      expect(diff.stableCount, 1);
    });

    test('default tolerance is exact: any movement is drift', () {
      final diff = compareToBaseline(
        baselineOf([judged('a', 0.90)]),
        reportOf([judged('a', 0.9000001)]),
      );
      expect(diff.drifted, hasLength(1));
    });

    test('NaN (boolean) scores never produce deltas', () {
      final diff = compareToBaseline(
        baselineOf([caseOf('a', 'x')]),
        reportOf([caseOf('a', 'x')]),
      );
      expect(diff.findings, isEmpty);
      expect(diff.stableCount, 1);
    });
  });

  group('suite-shape changes', () {
    test('a check added to a passing case reads as drift', () {
      final diff = compareToBaseline(
        baselineOf([caseOf('a', 'x')]),
        reportOf([
          CaseResult(
            name: 'a',
            output: 'x',
            results: [
              EvalResult.boolean('check', passed: true),
              EvalResult.boolean('brand-new', passed: true),
            ],
          ),
        ]),
      );
      final d = diff.drifted.single.checkDeltas.single;
      expect(d.criterion, 'brand-new');
      expect(d.baselinePassed, isNull);
      expect(d.currentPassed, isTrue);
    });

    test('a check removed from a passing case reads as drift', () {
      final baseline = Baseline(
        suiteName: 'suite',
        model: gemma3,
        createdAt: DateTime.utc(2026, 7, 8),
        entries: [
          BaselineEntry(
            name: 'a',
            passed: true,
            output: 'x',
            checks: const [
              BaselineCheck(criterion: 'check', passed: true),
              BaselineCheck(criterion: 'legacy', passed: true),
            ],
          ),
        ],
      );
      final diff = compareToBaseline(baseline, reportOf([caseOf('a', 'x')]));

      final d = diff.drifted.single.checkDeltas.single;
      expect(d.criterion, 'legacy');
      expect(d.baselinePassed, isTrue);
      expect(d.currentPassed, isNull);
    });
  });

  group('report metadata', () {
    test('modelChanged reflects the declared current model', () {
      final base = baselineOf([caseOf('a', 'x')]);
      final same = compareToBaseline(base, reportOf([caseOf('a', 'x')]),
          currentModel: gemma3);
      final changed = compareToBaseline(base, reportOf([caseOf('a', 'x')]),
          currentModel: gemma3n);
      final undeclared = compareToBaseline(base, reportOf([caseOf('a', 'x')]));

      expect(same.modelChanged, isFalse);
      expect(changed.modelChanged, isTrue);
      expect(undeclared.modelChanged, isFalse);
      expect(changed.summary(), contains('→'));
    });

    test('findings are ordered worst-first', () {
      final diff = compareToBaseline(
        baselineOf([
          caseOf('will-regress', 'x'),
          caseOf('will-vanish', 'x'),
          caseOf('will-drift', 'x'),
          caseOf('will-fix', 'x', passed: false),
        ]),
        reportOf([
          caseOf('will-regress', 'x', passed: false),
          caseOf('will-drift', 'x-moved'),
          caseOf('will-fix', 'x'),
          caseOf('brand-new', 'y'),
        ]),
      );

      expect(
        [for (final f in diff.findings) f.kind],
        [
          RegressionKind.regressed,
          RegressionKind.removed,
          RegressionKind.drifted,
          RegressionKind.added,
          RegressionKind.fixed,
        ],
      );
    });

    test('duplicate case names in the current report throw', () {
      expect(
        () => compareToBaseline(
          baselineOf([]),
          reportOf([caseOf('dup', 'a'), caseOf('dup', 'b')]),
        ),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('toJson', () {
    test('is a self-contained agent payload', () {
      final diff = compareToBaseline(
        baselineOf([caseOf('a', 'old')]),
        reportOf([caseOf('a', 'new', passed: false)]),
        currentModel: gemma3n,
      );
      final json = diff.toJson();

      expect(json['tool'], 'vouch');
      expect(json['formatVersion'], 1);
      expect(json['suite'], 'suite');
      expect(
        ((json['baseline'] as Map)['model'] as Map)['id'],
        'gemma-3-1b-it',
      );
      expect(((json['current'] as Map)['model'] as Map)['id'], 'gemma-3n-e2b');

      final counts = json['counts'] as Map;
      expect(counts['regressed'], 1);
      expect(counts['stable'], 0);
      expect(counts['total'], 1);

      final finding = (json['findings'] as List).single as Map;
      expect(finding['kind'], 'regressed');
      expect(finding['case'], 'a');
      expect(finding['baselineOutput'], 'old');
      expect(finding['currentOutput'], 'new');
      expect(finding['outputChanged'], isTrue);
    });
  });

  group('summary', () {
    test('truncates long outputs and flattens newlines', () {
      final longOut = 'line1\nline2 ${'x' * 200}';
      final diff = compareToBaseline(
        baselineOf([caseOf('a', 'short')]),
        reportOf([caseOf('a', longOut)]),
      );
      final text = diff.summary();
      expect(text, contains(r'\n'));
      expect(text, contains('…'));
      expect(text, isNot(contains('x' * 100)));
    });
  });
}
