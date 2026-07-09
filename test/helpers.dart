import 'package:llm_replay_eval/llm_replay_eval.dart';

/// A passing or failing case with a single boolean check named `check`,
/// unless [checks] overrides the full list.
CaseResult caseOf(
  String name,
  String output, {
  bool passed = true,
  List<EvalResult>? checks,
}) => CaseResult(
  name: name,
  output: output,
  results:
      checks ??
      [EvalResult.boolean('check', passed: passed, detail: 'from $name')],
);

EvalReport reportOf(List<CaseResult> cases, {String suite = 'suite'}) =>
    EvalReport(suite, cases);
