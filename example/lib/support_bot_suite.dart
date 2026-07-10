import 'package:llm_replay_eval/llm_replay_eval.dart';

import 'fake_on_device_model.dart';

/// The eval dataset a support bot must keep passing, whatever model runs
/// underneath. Requests double as cassette fingerprints, so the same suite
/// records against any model and replays deterministically forever.
EvalSuite supportBotSuite(FakeOnDeviceModel model) {
  EvalCase caseFor(String name, String prompt, List<Evaluator> checks) =>
      EvalCase(
        name: name,
        request: {'prompt': prompt},
        infer: () => model.generate(prompt),
        checks: checks,
      );

  return EvalSuite('support-bot', [
    caseFor('refund-policy', 'What is the refund policy? Answer as JSON.', [
      IsValidJson(),
      JsonHasKeys(['refundDays', 'requiresReceipt']),
    ]),
    caseFor('greeting', 'Greet the user.', [
      ContainsText('help', caseSensitive: false),
      MaxOutputLength(80),
    ]),
    caseFor('order-status', 'Summarize order #123 status.', [
      ContainsText('order', caseSensitive: false),
    ]),
  ]);
}
