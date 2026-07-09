import 'package:llm_replay_eval/llm_replay_eval.dart';

import 'model_info.dart';

/// Thrown when a baseline file can't be parsed or has an unsupported format
/// version.
class BaselineFormatException implements Exception {
  BaselineFormatException(this.message);

  final String message;

  @override
  String toString() => 'BaselineFormatException: $message';
}

/// One evaluator verdict frozen in a baseline.
class BaselineCheck {
  const BaselineCheck({
    required this.criterion,
    required this.passed,
    this.score,
    this.detail,
  });

  factory BaselineCheck.fromResult(EvalResult result) => BaselineCheck(
    criterion: result.criterion,
    passed: result.passed,
    score: result.hasScore ? result.score : null,
    detail: result.detail,
  );

  factory BaselineCheck.fromJson(Map<String, Object?> json) {
    final criterion = json['criterion'];
    final passed = json['passed'];
    final score = json['score'];
    final detail = json['detail'];
    if (criterion is! String || passed is! bool) {
      throw BaselineFormatException(
        'Baseline check must have a string "criterion" and bool "passed".',
      );
    }
    if (score is! num?) {
      throw BaselineFormatException(
        'Baseline check "$criterion" has a non-numeric "score".',
      );
    }
    if (detail is! String?) {
      throw BaselineFormatException(
        'Baseline check "$criterion" has a non-string "detail".',
      );
    }
    return BaselineCheck(
      criterion: criterion,
      passed: passed,
      score: score?.toDouble(),
      detail: detail,
    );
  }

  final String criterion;
  final bool passed;

  /// The 0..1 score where the check produced one, else null.
  final double? score;
  final String? detail;

  Map<String, Object?> toJson() => {
    'criterion': criterion,
    'passed': passed,
    if (score != null) 'score': score,
    if (detail != null) 'detail': detail,
  };
}

/// One eval case's frozen outcome: the output the trusted model produced and
/// every check's verdict on it.
class BaselineEntry {
  BaselineEntry({
    required this.name,
    required this.passed,
    required this.output,
    required List<BaselineCheck> checks,
  }) : checks = List.unmodifiable(checks);

  factory BaselineEntry.fromCaseResult(CaseResult result) => BaselineEntry(
    name: result.name,
    passed: result.passed,
    output: result.output,
    checks: [for (final r in result.results) BaselineCheck.fromResult(r)],
  );

  factory BaselineEntry.fromJson(Map<String, Object?> json) {
    final name = json['name'];
    final passed = json['passed'];
    final output = json['output'];
    final checks = json['checks'];
    if (name is! String || passed is! bool || output is! String) {
      throw BaselineFormatException(
        'Baseline entry must have string "name", bool "passed" and '
        'string "output".',
      );
    }
    // A corrupt check is never skipped: dropping one would change what this
    // entry vouches for without anyone noticing.
    if (checks is! List) {
      throw BaselineFormatException(
        'Baseline entry "$name" must have a list of "checks".',
      );
    }
    return BaselineEntry(
      name: name,
      passed: passed,
      output: output,
      checks: [
        for (final c in checks)
          if (c is Map<String, Object?>)
            BaselineCheck.fromJson(c)
          else
            throw BaselineFormatException(
              'Baseline entry "$name" contains a non-object check.',
            ),
      ],
    );
  }

  final String name;
  final bool passed;
  final String output;
  final List<BaselineCheck> checks;

  /// The frozen verdict for [criterion], or null if the baseline suite had no
  /// such check on this case.
  BaselineCheck? checkFor(String criterion) {
    for (final c in checks) {
      if (c.criterion == criterion) return c;
    }
    return null;
  }

  Map<String, Object?> toJson() => {
    'name': name,
    'passed': passed,
    'output': output,
    'checks': [for (final c in checks) c.toJson()],
  };
}

/// A frozen snapshot of an [EvalReport] produced by a known [model].
///
/// Freeze one while the suite runs against a model you trust; later runs —
/// after a model upgrade, a new quantization, or an OS update that swapped
/// the model under you — are diffed against it with `compareToBaseline`.
class Baseline {
  Baseline({
    required this.suiteName,
    required this.model,
    required this.createdAt,
    required List<BaselineEntry> entries,
  }) : entries = List.unmodifiable(entries),
       _byName = {for (final e in entries) e.name: e} {
    if (_byName.length != entries.length) {
      final seen = <String>{};
      final dup = entries.firstWhere((e) => !seen.add(e.name)).name;
      throw ArgumentError(
        'Duplicate case name "$dup" — baseline cases must be uniquely named '
        'so later runs can be matched against them.',
      );
    }
  }

  /// Freezes [report] as the trusted reference produced by [model].
  factory Baseline.fromReport(
    EvalReport report, {
    required ModelInfo model,
    DateTime? createdAt,
  }) => Baseline(
    suiteName: report.suiteName,
    model: model,
    createdAt: createdAt ?? DateTime.now(),
    entries: [
      for (final c in report.cases) BaselineEntry.fromCaseResult(c),
    ],
  );

  /// Parses the JSON produced by [toJson].
  ///
  /// Throws [BaselineFormatException] on a malformed document or an
  /// unsupported [formatVersion] (so an old vouch never silently misreads a
  /// newer baseline).
  factory Baseline.fromJson(Map<String, Object?> json) {
    final version = json['formatVersion'];
    if (version != formatVersion) {
      throw BaselineFormatException(
        'Unsupported baseline format version $version '
        '(this version of vouch reads version $formatVersion).',
      );
    }
    final suite = json['suite'];
    final model = json['model'];
    final createdAt = json['createdAt'];
    final entries = json['entries'];
    if (suite is! String ||
        model is! Map<String, Object?> ||
        createdAt is! String ||
        entries is! List) {
      throw BaselineFormatException(
        'Baseline must have string "suite", object "model", string '
        '"createdAt" and list "entries".',
      );
    }
    try {
      return Baseline(
        suiteName: suite,
        model: ModelInfo.fromJson(model),
        createdAt: DateTime.parse(createdAt),
        // A corrupt entry is never skipped: silently dropping one would
        // shrink coverage and let a vanished case pass the gate as CLEAN.
        entries: [
          for (final e in entries)
            if (e is Map<String, Object?>)
              BaselineEntry.fromJson(e)
            else
              throw BaselineFormatException(
                'Baseline "entries" contains a non-object item.',
              ),
        ],
      );
    } on FormatException catch (e) {
      throw BaselineFormatException(e.message);
    } on ArgumentError catch (e) {
      // e.g. duplicate case names inside the document.
      throw BaselineFormatException(e.message.toString());
    }
  }

  /// The on-disk format version written by [toJson].
  static const int formatVersion = 1;

  final String suiteName;

  /// The model this baseline was recorded under.
  final ModelInfo model;

  final DateTime createdAt;
  final List<BaselineEntry> entries;
  final Map<String, BaselineEntry> _byName;

  /// The frozen entry for the case named [name], or null if the baseline
  /// doesn't contain it.
  BaselineEntry? entryFor(String name) => _byName[name];

  Map<String, Object?> toJson() => {
    'formatVersion': formatVersion,
    'suite': suiteName,
    'model': model.toJson(),
    // Always UTC, so the recorded instant is unambiguous across machines.
    'createdAt': createdAt.toUtc().toIso8601String(),
    'entries': [for (final e in entries) e.toJson()],
  };
}
