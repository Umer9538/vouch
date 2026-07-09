import 'regression.dart';

/// Thrown by [expectNoRegression] when the diff contains changes the gate
/// won't vouch for. Any test framework reports a thrown error as a failure,
/// so the gate works identically under `flutter_test` and `dart test`.
class RegressionError extends Error {
  RegressionError(this.report, this.message);

  /// The full diff, for callers that catch and inspect programmatically.
  final RegressionReport report;

  final String message;

  @override
  String toString() => message;
}

/// The CI gate: throws a [RegressionError] carrying the readable diff when
/// [report] contains anything the baseline can't vouch for.
///
/// Fails on, in order of severity:
///
/// - **regressed** cases — always. A baseline-passing case failing after a
///   model swap is the exact silent breakage this package exists to catch.
/// - **removed** cases — unless [failOnRemoved] is false. A case vanishing
///   from the suite shrinks coverage, which is how regressions hide.
/// - **added failing** cases — unless [failOnAddedFailing] is false. New
///   cases that fail aren't regressions, but letting them through would make
///   this gate the only green light in CI over a failing suite.
/// - **drifted** cases — only when [failOnDrift] is true, for suites whose
///   outputs must stay byte-identical.
void expectNoRegression(
  RegressionReport report, {
  bool failOnRemoved = true,
  bool failOnAddedFailing = true,
  bool failOnDrift = false,
}) {
  final problems = [
    if (report.hasRegressions) '${report.regressed.length} regressed',
    if (failOnRemoved && report.removed.isNotEmpty)
      '${report.removed.length} removed',
    if (failOnAddedFailing && report.addedFailing.isNotEmpty)
      '${report.addedFailing.length} added-and-failing',
    if (failOnDrift && report.drifted.isNotEmpty)
      '${report.drifted.length} drifted',
  ];
  if (problems.isEmpty) return;
  throw RegressionError(
    report,
    'Model regression gate failed (${problems.join(', ')}).\n\n'
    '${report.summary()}',
  );
}
