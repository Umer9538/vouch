/// Catch silent on-device LLM regressions before your users do.
///
/// `vouch` freezes a [Baseline] of an `llm_replay_eval` report produced by a
/// model you trust, compares every later run against it with
/// [compareToBaseline], and fails CI via [expectNoRegression] when a model
/// swap, quantization change, or OS update silently changed behavior.
library;

export 'src/baseline.dart';
export 'src/baseline_store.dart';
export 'src/gate.dart';
export 'src/model_info.dart';
export 'src/regression.dart';
