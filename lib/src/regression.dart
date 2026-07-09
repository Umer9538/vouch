import 'package:llm_replay_eval/llm_replay_eval.dart';

import 'baseline.dart';
import 'model_info.dart';

/// How a case's outcome moved between the baseline and the current run.
enum RegressionKind {
  /// Passed in the baseline, fails now — the bucket that blocks CI.
  regressed,

  /// Present in the baseline, missing from the current run. Coverage
  /// silently shrank, which is how regressions hide.
  removed,

  /// Passes in both runs, but the output, a score, or the set of checks
  /// evaluated against it changed.
  drifted,

  /// Failed in both runs.
  stillFailing,

  /// New case, absent from the baseline.
  added,

  /// Failed in the baseline, passes now.
  fixed,
}

/// One check's verdict on both sides of the comparison. A null baseline or
/// current side means the check (or the whole case) didn't exist on that
/// side.
class CheckDelta {
  const CheckDelta({
    required this.criterion,
    this.baselinePassed,
    this.currentPassed,
    this.baselineScore,
    this.currentScore,
    this.detail,
  });

  final String criterion;
  final bool? baselinePassed;
  final bool? currentPassed;
  final double? baselineScore;
  final double? currentScore;

  /// The current run's explanation, most useful when the check now fails.
  final String? detail;

  /// Score movement (current − baseline) when both sides have a score.
  double? get scoreDelta =>
      baselineScore == null || currentScore == null
          ? null
          : currentScore! - baselineScore!;

  Map<String, Object?> toJson() => {
    'criterion': criterion,
    if (baselinePassed != null) 'baselinePassed': baselinePassed,
    if (currentPassed != null) 'currentPassed': currentPassed,
    if (baselineScore != null) 'baselineScore': baselineScore,
    if (currentScore != null) 'currentScore': currentScore,
    if (scoreDelta != null) 'scoreDelta': scoreDelta,
    if (detail != null) 'detail': detail,
  };
}

/// One case's movement between the baseline and the current run, with enough
/// context to act on it without re-running anything.
class RegressionFinding {
  RegressionFinding({
    required this.kind,
    required this.caseName,
    this.baselinePassed,
    this.currentPassed,
    this.baselineOutput,
    this.currentOutput,
    required List<CheckDelta> checkDeltas,
  }) : checkDeltas = List.unmodifiable(checkDeltas);

  final RegressionKind kind;
  final String caseName;
  final bool? baselinePassed;
  final bool? currentPassed;
  final String? baselineOutput;
  final String? currentOutput;

  /// The checks that moved (or, for one-sided cases, the ones that fail).
  final List<CheckDelta> checkDeltas;

  /// Whether the raw model output changed (null for one-sided cases).
  bool? get outputChanged =>
      baselineOutput == null || currentOutput == null
          ? null
          : baselineOutput != currentOutput;

  Map<String, Object?> toJson() => {
    'kind': kind.name,
    'case': caseName,
    if (baselinePassed != null) 'baselinePassed': baselinePassed,
    if (currentPassed != null) 'currentPassed': currentPassed,
    if (outputChanged != null) 'outputChanged': outputChanged,
    if (baselineOutput != null) 'baselineOutput': baselineOutput,
    if (currentOutput != null) 'currentOutput': currentOutput,
    if (checkDeltas.isNotEmpty)
      'checks': [for (final d in checkDeltas) d.toJson()],
  };
}

/// The result of diffing a current [EvalReport] against a [Baseline]:
/// which cases regressed, drifted, got fixed, appeared or disappeared.
class RegressionReport {
  RegressionReport({
    required this.suiteName,
    required this.baselineModel,
    required this.baselineCreatedAt,
    this.currentModel,
    required List<RegressionFinding> findings,
    required this.stableCount,
  }) : findings = List.unmodifiable(findings);

  final String suiteName;
  final ModelInfo baselineModel;
  final DateTime baselineCreatedAt;

  /// The model the current run used, when the caller provided it.
  final ModelInfo? currentModel;

  /// Every non-stable case, ordered worst-first: regressed, removed,
  /// drifted, still failing, added, fixed.
  final List<RegressionFinding> findings;

  /// Cases that passed in both runs with identical output and steady scores.
  final int stableCount;

  /// The findings of one [kind].
  List<RegressionFinding> ofKind(RegressionKind kind) =>
      [for (final f in findings) if (f.kind == kind) f];

  List<RegressionFinding> get regressed => ofKind(RegressionKind.regressed);
  List<RegressionFinding> get removed => ofKind(RegressionKind.removed);
  List<RegressionFinding> get drifted => ofKind(RegressionKind.drifted);
  List<RegressionFinding> get stillFailing =>
      ofKind(RegressionKind.stillFailing);
  List<RegressionFinding> get added => ofKind(RegressionKind.added);
  List<RegressionFinding> get fixed => ofKind(RegressionKind.fixed);

  /// Added cases that fail — new work the baseline can't vouch for.
  List<RegressionFinding> get addedFailing =>
      [for (final f in added) if (f.currentPassed == false) f];

  /// True when at least one baseline-passing case now fails.
  bool get hasRegressions => regressed.isNotEmpty;

  /// True when the caller declared a current model different from the
  /// baseline's — the usual reason a diff exists at all.
  bool get modelChanged =>
      currentModel != null && currentModel!.label != baselineModel.label;

  int get totalCompared => findings.length + stableCount;

  /// Agent-legible payload: schema-stable JSON with full outputs, so a
  /// coding agent (or a dashboard) can act on the diff without re-running.
  Map<String, Object?> toJson() => {
    'tool': 'vouch',
    'formatVersion': 1,
    'suite': suiteName,
    'baseline': {
      'model': baselineModel.toJson(),
      'createdAt': baselineCreatedAt.toIso8601String(),
    },
    if (currentModel != null) 'current': {'model': currentModel!.toJson()},
    'counts': {
      for (final kind in RegressionKind.values) kind.name: ofKind(kind).length,
      'stable': stableCount,
      'total': totalCompared,
    },
    'findings': [for (final f in findings) f.toJson()],
  };

  /// A compact, readable summary suitable for printing to the console.
  String summary() {
    final status = hasRegressions ? 'REGRESSED' : 'CLEAN';
    final buffer = StringBuffer()
      ..writeln(
        'vouch: "$suiteName" vs baseline ${baselineModel.label} '
        '(${baselineCreatedAt.toIso8601String().split('T').first}) — $status',
      );
    if (modelChanged) {
      buffer.writeln('  model: ${baselineModel.label} → ${currentModel!.label}');
    }
    final counts = [
      for (final kind in RegressionKind.values)
        if (ofKind(kind).isNotEmpty) '${ofKind(kind).length} ${_label(kind)}',
      '$stableCount stable',
    ];
    buffer.writeln('  ${counts.join(' · ')}');
    for (final f in findings) {
      buffer.writeln('  ${_mark(f.kind)} ${_label(f.kind).toUpperCase()} '
          '${f.caseName}');
      for (final d in f.checkDeltas) {
        buffer.writeln('      ${d.criterion}: ${_verdict(d.baselinePassed)}'
            ' → ${_verdict(d.currentPassed)}'
            '${d.scoreDelta == null ? '' : ' (score ${d.baselineScore!.toStringAsFixed(2)} → ${d.currentScore!.toStringAsFixed(2)})'}'
            '${d.detail == null ? '' : ' — ${d.detail}'}');
      }
      if (f.outputChanged == true) {
        buffer.writeln('      output: ${_snip(f.baselineOutput!)} '
            '→ ${_snip(f.currentOutput!)}');
      }
    }
    return buffer.toString().trimRight();
  }

  static String _label(RegressionKind kind) => switch (kind) {
    RegressionKind.regressed => 'regressed',
    RegressionKind.removed => 'removed',
    RegressionKind.drifted => 'drifted',
    RegressionKind.stillFailing => 'still failing',
    RegressionKind.added => 'added',
    RegressionKind.fixed => 'fixed',
  };

  static String _mark(RegressionKind kind) => switch (kind) {
    RegressionKind.regressed || RegressionKind.removed => '✗',
    RegressionKind.drifted || RegressionKind.stillFailing => '~',
    RegressionKind.added || RegressionKind.fixed => '+',
  };

  static String _verdict(bool? passed) =>
      passed == null ? '—' : (passed ? 'PASS' : 'FAIL');

  static String _snip(String output) {
    final flat = output.replaceAll('\n', r'\n');
    return flat.length <= 80 ? '"$flat"' : '"${flat.substring(0, 77)}…"';
  }
}

/// Diffs [current] against [baseline], matching cases by name.
///
/// Score movement within [scoreTolerance] does not count as drift — useful
/// when a live (non-cassetted) judge introduces small jitter. Output
/// comparison is exact: in the deterministic replay world of
/// `llm_replay_eval`, any byte difference is a real behavior change.
///
/// Throws [ArgumentError] if [current] contains duplicate case names —
/// silently keeping one of them could hide a regression — or if the
/// baseline was recorded for a different suite: diffing unrelated suites
/// would bucket everything as added/removed and vouch for nothing.
RegressionReport compareToBaseline(
  Baseline baseline,
  EvalReport current, {
  ModelInfo? currentModel,
  double scoreTolerance = 0.0,
}) {
  if (scoreTolerance.isNaN || scoreTolerance < 0) {
    throw ArgumentError.value(
      scoreTolerance,
      'scoreTolerance',
      'must be a non-negative number',
    );
  }
  if (baseline.suiteName != current.suiteName) {
    throw ArgumentError(
      'Baseline is for suite "${baseline.suiteName}" but the report is for '
      'suite "${current.suiteName}" — comparing across suites would produce '
      'a meaningless diff. Load the right baseline, or re-record it under '
      'the new suite name.',
    );
  }
  final currentByName = <String, CaseResult>{};
  for (final c in current.cases) {
    if (currentByName.containsKey(c.name)) {
      throw ArgumentError(
        'Duplicate case name "${c.name}" in the current report — cases must '
        'be uniquely named so they can be matched against the baseline.',
      );
    }
    currentByName[c.name] = c;
  }

  final findings = <RegressionFinding>[];
  var stable = 0;

  for (final entry in baseline.entries) {
    final now = currentByName.remove(entry.name);
    if (now == null) {
      findings.add(
        RegressionFinding(
          kind: RegressionKind.removed,
          caseName: entry.name,
          baselinePassed: entry.passed,
          baselineOutput: entry.output,
          checkDeltas: const [],
        ),
      );
      continue;
    }

    final deltas = _deltas(entry, now, scoreTolerance);
    final kind = _classify(entry, now, deltas, scoreTolerance);
    if (kind == null) {
      stable++;
      continue;
    }
    findings.add(
      RegressionFinding(
        kind: kind,
        caseName: entry.name,
        baselinePassed: entry.passed,
        currentPassed: now.passed,
        baselineOutput: entry.output,
        currentOutput: now.output,
        checkDeltas: deltas,
      ),
    );
  }

  // Whatever the baseline didn't claim is new.
  for (final now in currentByName.values) {
    findings.add(
      RegressionFinding(
        kind: RegressionKind.added,
        caseName: now.name,
        currentPassed: now.passed,
        currentOutput: now.output,
        checkDeltas: [
          for (final r in now.results)
            if (!r.passed)
              CheckDelta(
                criterion: r.criterion,
                currentPassed: r.passed,
                currentScore: r.hasScore ? r.score : null,
                detail: r.detail,
              ),
        ],
      ),
    );
  }

  findings.sort((a, b) => a.kind.index.compareTo(b.kind.index));

  return RegressionReport(
    suiteName: current.suiteName,
    baselineModel: baseline.model,
    baselineCreatedAt: baseline.createdAt,
    currentModel: currentModel,
    findings: findings,
    stableCount: stable,
  );
}

/// Which bucket a case present in both runs falls into, or null when stable.
RegressionKind? _classify(
  BaselineEntry entry,
  CaseResult now,
  List<CheckDelta> deltas,
  double scoreTolerance,
) {
  if (entry.passed && !now.passed) return RegressionKind.regressed;
  if (!entry.passed && now.passed) return RegressionKind.fixed;
  if (!entry.passed && !now.passed) return RegressionKind.stillFailing;
  // Both passed: drift when the output moved or any score moved beyond
  // tolerance.
  if (entry.output != now.output || deltas.isNotEmpty) {
    return RegressionKind.drifted;
  }
  return null;
}

/// The checks worth reporting for a case present in both runs: any check
/// whose pass state flipped, whose score moved beyond [tolerance] or
/// appeared/disappeared, or that exists on only one side.
///
/// Checks are matched by criterion name; when a case has several checks
/// sharing a name they pair positionally, so a byte-identical rerun never
/// fabricates drift and a real movement in the second twin is never masked
/// by the first. Non-finite scores (NaN from boolean checks, or garbage
/// like infinity) are treated as "no score".
List<CheckDelta> _deltas(
  BaselineEntry entry,
  CaseResult now,
  double tolerance,
) {
  final beforeByName = <String, List<BaselineCheck>>{};
  for (final c in entry.checks) {
    beforeByName.putIfAbsent(c.criterion, () => []).add(c);
  }
  final nowByName = <String, List<EvalResult>>{};
  for (final r in now.results) {
    nowByName.putIfAbsent(r.criterion, () => []).add(r);
  }

  final deltas = <CheckDelta>[];
  for (final MapEntry(key: criterion, value: currents) in nowByName.entries) {
    final befores = beforeByName.remove(criterion) ?? const <BaselineCheck>[];
    final pairs =
        currents.length > befores.length ? currents.length : befores.length;
    for (var i = 0; i < pairs; i++) {
      final before = i < befores.length ? befores[i] : null;
      final r = i < currents.length ? currents[i] : null;
      final baselineScore =
          before?.score?.isFinite ?? false ? before!.score : null;
      final currentScore =
          r != null && r.hasScore && r.score.isFinite ? r.score : null;
      final delta = CheckDelta(
        criterion: criterion,
        baselinePassed: before?.passed,
        currentPassed: r?.passed,
        baselineScore: baselineScore,
        currentScore: currentScore,
        detail: r?.detail,
      );
      final oneSided = before == null || r == null;
      final flipped = !oneSided && before.passed != r.passed;
      final scoreMoved =
          delta.scoreDelta != null && delta.scoreDelta!.abs() > tolerance;
      // A quality signal appearing or vanishing is a change, not stability.
      final presenceChanged =
          !oneSided && (baselineScore == null) != (currentScore == null);
      if (oneSided || flipped || scoreMoved || presenceChanged) {
        deltas.add(delta);
      }
    }
  }

  for (final befores in beforeByName.values) {
    for (final before in befores) {
      deltas.add(
        CheckDelta(
          criterion: before.criterion,
          baselinePassed: before.passed,
          baselineScore: before.score?.isFinite ?? false ? before.score : null,
        ),
      );
    }
  }

  return deltas;
}
