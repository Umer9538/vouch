// ignore_for_file: avoid_print
import 'package:llm_replay_eval/llm_replay_eval.dart';
import 'package:vouch/vouch.dart';

import 'fake_on_device_model.dart';
import 'support_bot_suite.dart';

/// The whole story in one run: freeze a baseline under the model you trust,
/// "upgrade" the model, and watch vouch name exactly what silently broke.
Future<void> main() async {
  final v1Report = await supportBotSuite(
    FakeOnDeviceModel(1),
  ).run(ReplaySession(cassette: Cassette('demo-v1'), mode: ReplayMode.auto));
  final baseline = Baseline.fromReport(
    v1Report,
    model: const ModelInfo(id: 'fake-slm', version: '1', quantization: 'q4'),
  );

  final v2Report = await supportBotSuite(
    FakeOnDeviceModel(2),
  ).run(ReplaySession(cassette: Cassette('demo-v2'), mode: ReplayMode.auto));
  final diff = compareToBaseline(
    baseline,
    v2Report,
    currentModel: const ModelInfo(
      id: 'fake-slm',
      version: '2',
      quantization: 'q4',
    ),
  );

  print(diff.summary());
  // In CI you would instead call: expectNoRegression(diff);
}
