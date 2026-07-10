import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:llm_replay_eval/llm_replay_eval.dart';
import 'package:vouch/vouch.dart';

import 'helpers.dart';

void main() {
  const gemma3 = ModelInfo(id: 'gemma-3-1b-it', quantization: 'q4');
  const gemma3n = ModelInfo(id: 'gemma-3n-e2b', quantization: 'q4');

  Baseline baselineOf(List<CaseResult> cases) => Baseline.fromReport(
    reportOf(cases),
    model: gemma3,
    createdAt: DateTime.utc(2026, 7, 8),
  );

  CaseResult judgedCase(String name, double score) => CaseResult(
    name: name,
    output: 'same output',
    results: [EvalResult(criterion: 'judge', passed: true, score: score)],
  );

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

    test('an unchanged known failure is stable, not a finding', () {
      // Audit round 2: a byte-identical rerun of a baseline containing a
      // failing case fabricated a stillFailing finding every time.
      final cases = [caseOf('known-bad', 'nope', passed: false)];
      final diff = compareToBaseline(baselineOf(cases), reportOf(cases));
      expect(diff.findings, isEmpty);
      expect(diff.stableCount, 1);
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
      results: [EvalResult(criterion: 'judge', passed: true, score: score)],
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

    test('a score vanishing on a passing check is drift, not stable', () {
      // Audit round 1: a 0.9 quality signal disappearing (judge replaced by
      // a boolean check) was classified stable and the gate passed.
      final diff = compareToBaseline(
        baselineOf([judged('a', 0.9)]),
        reportOf([
          CaseResult(
            name: 'a',
            output: 'same output',
            results: [const EvalResult(criterion: 'judge', passed: true)],
          ),
        ]),
      );
      final d = diff.drifted.single.checkDeltas.single;
      expect(d.baselineScore, 0.9);
      expect(d.currentScore, isNull);
      expect(d.scoreDelta, isNull);
    });

    test('a score appearing on a passing check is drift, not stable', () {
      final diff = compareToBaseline(
        baselineOf([
          CaseResult(
            name: 'a',
            output: 'same output',
            results: [const EvalResult(criterion: 'judge', passed: true)],
          ),
        ]),
        reportOf([judged('a', 0.9)]),
      );
      final d = diff.drifted.single.checkDeltas.single;
      expect(d.baselineScore, isNull);
      expect(d.currentScore, 0.9);
    });

    test('an added case with a non-finite score stays JSON-encodable', () {
      // Audit round 2: the added-case branch missed the isFinite guard, so
      // an Infinity score leaked into toJson and jsonEncode crashed.
      final diff = compareToBaseline(
        baselineOf([]),
        reportOf([
          CaseResult(
            name: 'fresh',
            output: 'x',
            results: [
              const EvalResult(
                criterion: 'j',
                passed: false,
                score: double.infinity,
              ),
            ],
          ),
        ]),
      );
      expect(diff.addedFailing.single.checkDeltas.single.currentScore, isNull);
      expect(() => jsonEncode(diff.toJson()), returnsNormally);
    });

    test('a score delta overflowing to infinity is omitted from JSON', () {
      // Audit round 2: two finite scores (±maxFinite) subtract to
      // -Infinity, which JSON can't carry — jsonEncode crashed.
      final diff = compareToBaseline(
        baselineOf([judged('a', double.maxFinite)]),
        reportOf([judged('a', -double.maxFinite)]),
      );
      final d = diff.drifted.single.checkDeltas.single;
      expect(d.scoreDelta, double.negativeInfinity); // still visible in Dart
      expect(d.toJson().containsKey('scoreDelta'), isFalse);
      expect(() => jsonEncode(diff.toJson()), returnsNormally);
    });

    test('a non-finite current score is treated as unscored and the '
        'agent payload stays JSON-encodable', () {
      final diff = compareToBaseline(
        baselineOf([judged('a', 0.9)]),
        reportOf([judged('a', double.infinity)]),
      );
      // Scored -> garbage reads as the score vanishing: drift.
      final d = diff.drifted.single.checkDeltas.single;
      expect(d.currentScore, isNull);
      expect(() => jsonEncode(diff.toJson()), returnsNormally);
    });
  });

  group('duplicate criterion names', () {
    List<EvalResult> twoLens(double a, double b) => [
      EvalResult(criterion: 'len', passed: true, score: a),
      EvalResult(criterion: 'len', passed: true, score: b),
    ];

    test('a byte-identical rerun with duplicate criteria is stable', () {
      // Audit round 1: first-name-wins pairing fabricated a phantom
      // 0.2 -> 0.9 drift out of an identical run.
      final diff = compareToBaseline(
        baselineOf([
          CaseResult(name: 'c', output: 'x', results: twoLens(0.2, 0.9)),
        ]),
        reportOf([
          CaseResult(name: 'c', output: 'x', results: twoLens(0.2, 0.9)),
        ]),
      );
      expect(diff.findings, isEmpty);
      expect(diff.stableCount, 1);
    });

    test('a real movement in the second duplicate is reported', () {
      // Audit round 1: the genuine 0.2 -> 0.9 change was silently dropped
      // because the second current check matched the first baseline check.
      final diff = compareToBaseline(
        baselineOf([
          CaseResult(name: 'c', output: 'x', results: twoLens(0.9, 0.2)),
        ]),
        reportOf([
          CaseResult(name: 'c', output: 'x', results: twoLens(0.9, 0.9)),
        ]),
      );
      final d = diff.drifted.single.checkDeltas.single;
      expect(d.baselineScore, 0.2);
      expect(d.currentScore, 0.9);
      expect(d.scoreDelta, closeTo(0.7, 1e-9));
    });

    test('reordering multiset-identical twins is stable, not drift', () {
      // Audit round 2: positional pairing fabricated two mirror-image
      // deltas (+0.7/-0.7) when identical twins swapped emission order.
      final diff = compareToBaseline(
        baselineOf([
          CaseResult(name: 'c', output: 'x', results: twoLens(0.9, 0.2)),
        ]),
        reportOf([
          CaseResult(name: 'c', output: 'x', results: twoLens(0.2, 0.9)),
        ]),
      );
      expect(diff.findings, isEmpty);
      expect(diff.stableCount, 1);
    });

    test('a deleted twin is reported as removed, not as its sibling '
        'moving', () {
      // Audit round 2: baseline [0.3, 0.9] vs current [0.9] claimed the
      // surviving 0.9 check "moved 0.3 -> 0.9". The truthful story is that
      // the 0.3 twin vanished.
      final diff = compareToBaseline(
        baselineOf([
          CaseResult(name: 'c', output: 'x', results: twoLens(0.3, 0.9)),
        ]),
        reportOf([
          CaseResult(
            name: 'c',
            output: 'x',
            results: [
              const EvalResult(criterion: 'len', passed: true, score: 0.9),
            ],
          ),
        ]),
      );
      final d = diff.drifted.single.checkDeltas.single;
      expect(d.baselineScore, 0.3);
      expect(d.currentPassed, isNull); // one-sided: the twin is gone
    });

    test('a regressed twin is blamed correctly after reordering', () {
      // Audit round 2: baseline [pass 0.9, pass 0.2] vs current
      // [pass 0.2, FAIL 0.9] blamed the wrong twin ("PASS -> FAIL, score
      // 0.20 -> 0.90"). The unchanged 0.2 twin must match away, leaving
      // the 0.9 twin's flip with its own steady score.
      final diff = compareToBaseline(
        baselineOf([
          CaseResult(name: 'c', output: 'x', results: twoLens(0.9, 0.2)),
        ]),
        reportOf([
          CaseResult(
            name: 'c',
            output: 'x',
            results: [
              const EvalResult(criterion: 'len', passed: true, score: 0.2),
              const EvalResult(criterion: 'len', passed: false, score: 0.9),
            ],
          ),
        ]),
      );
      final d = diff.regressed.single.checkDeltas.single;
      expect(d.baselinePassed, isTrue);
      expect(d.currentPassed, isFalse);
      expect(d.baselineScore, 0.9);
      expect(d.currentScore, 0.9);
    });

    test('a duplicate count mismatch surfaces as a one-sided delta', () {
      final diff = compareToBaseline(
        baselineOf([
          CaseResult(
            name: 'c',
            output: 'x',
            results: [
              const EvalResult(criterion: 'len', passed: true, score: 0.5),
            ],
          ),
        ]),
        reportOf([
          CaseResult(name: 'c', output: 'x', results: twoLens(0.5, 0.8)),
        ]),
      );
      final d = diff.drifted.single.checkDeltas.single;
      expect(d.baselinePassed, isNull);
      expect(d.currentScore, 0.8);
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
              // Mirrors what fromResult freezes for EvalResult.boolean,
              // which carries score 1.0.
              BaselineCheck(criterion: 'check', passed: true, score: 1.0),
              BaselineCheck(criterion: 'legacy', passed: true, score: 1.0),
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
      final same = compareToBaseline(
        base,
        reportOf([caseOf('a', 'x')]),
        currentModel: gemma3,
      );
      final changed = compareToBaseline(
        base,
        reportOf([caseOf('a', 'x')]),
        currentModel: gemma3n,
      );
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

    test('comparing against a baseline from another suite throws', () {
      // Audit round 1: a baseline for suite "B" was silently accepted for
      // suite "A", producing an all-added/all-removed nonsense diff.
      final base = Baseline.fromReport(
        reportOf([caseOf('a', 'x')], suite: 'chat-v1'),
        model: gemma3,
      );
      expect(
        () => compareToBaseline(base, reportOf([caseOf('a', 'x')])),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            contains('chat-v1'),
          ),
        ),
      );
    });

    test('a negative or NaN scoreTolerance throws instead of fabricating '
        'phantom drift', () {
      final base = baselineOf([caseOf('a', 'x')]);
      for (final bad in [-0.1, double.nan]) {
        expect(
          () => compareToBaseline(
            base,
            reportOf([caseOf('a', 'x')]),
            scoreTolerance: bad,
          ),
          throwsA(isA<ArgumentError>()),
          reason: 'tolerance: $bad',
        );
      }
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
    test('a vanished score is named in the summary line', () {
      // Audit round 2: presence-change drift rendered as an
      // information-free "PASS → PASS" with no hint of why.
      final diff = compareToBaseline(
        baselineOf([judgedCase('a', 0.5)]),
        reportOf([
          CaseResult(
            name: 'a',
            output: 'same output',
            results: [const EvalResult(criterion: 'judge', passed: true)],
          ),
        ]),
      );
      expect(diff.summary(), contains('(score 0.50 → none)'));
    });

    test('truncation never splits an emoji surrogate pair', () {
      // Audit round 1: cutting at code unit 77 could strand a lone high
      // surrogate at the end of the snippet. Place an emoji exactly across
      // the cut: 76 ASCII chars, then 🎉 occupying units 76-77.
      final tricky = '${'a' * 76}🎉 and plenty of tail text to force a cut';
      final diff = compareToBaseline(
        baselineOf([caseOf('a', 'short')]),
        reportOf([caseOf('a', tricky)]),
      );
      final text = diff.summary();
      for (var i = 0; i < text.length; i++) {
        final unit = text.codeUnitAt(i);
        final isHigh = unit >= 0xD800 && unit <= 0xDBFF;
        if (isHigh) {
          expect(i + 1, lessThan(text.length), reason: 'lone high surrogate');
          final next = text.codeUnitAt(i + 1);
          expect(
            next >= 0xDC00 && next <= 0xDFFF,
            isTrue,
            reason: 'unpaired surrogate at $i',
          );
          i++;
        } else {
          expect(
            unit >= 0xDC00 && unit <= 0xDFFF,
            isFalse,
            reason: 'orphan low surrogate at $i',
          );
        }
      }
    });

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
