// The vouch workflow, end to end, with real cassettes and a committed
// baseline:
//
//   1. Run the eval suite against the model you trust (v1). The first run
//      records a cassette and freezes the baseline; every later run replays
//      offline and is held to it.
//   2. "Upgrade" the model (v2) and diff against the same baseline. The
//      upgrade answers one question in prose instead of JSON — no crash, no
//      error, just a silently broken app. vouch names it and fails the gate.
import 'package:flutter_test/flutter_test.dart';
import 'package:llm_replay_eval/llm_replay_eval.dart';
import 'package:vouch/vouch.dart';
import 'package:vouch_example/fake_on_device_model.dart';
import 'package:vouch_example/support_bot_suite.dart';

const v1 = ModelInfo(id: 'fake-slm', version: '1', quantization: 'q4');
const v2 = ModelInfo(id: 'fake-slm', version: '2', quantization: 'q4');

void main() {
  final cassettes = CassetteStore('cassettes');
  final baselines = BaselineStore('baselines');

  Future<EvalReport> run(FakeOnDeviceModel model, String cassette) =>
      supportBotSuite(model).run(
        ReplaySession.open(
          name: cassette,
          mode: ReplayMode.auto,
          store: cassettes,
        ),
      );

  test('the shipped model still matches its baseline', () async {
    final report = await run(FakeOnDeviceModel(1), 'support-bot-v1');

    // First run freezes the baseline; every later run is held to it.
    var baseline = baselines.loadOrNull('support-bot');
    if (baseline == null) {
      baseline = Baseline.fromReport(
        report,
        model: v1,
        createdAt: DateTime.utc(2026, 7, 10),
      );
      baselines.save(baseline);
    }

    expectNoRegression(compareToBaseline(baseline, report, currentModel: v1));
  });

  test('the model upgrade is caught before release', () async {
    final report = await run(FakeOnDeviceModel(2), 'support-bot-v2');
    final diff = compareToBaseline(
      baselines.load('support-bot'),
      report,
      currentModel: v2,
    );

    // The prose refund answer breaks both JSON checks: regressed.
    expect(diff.regressed.single.caseName, 'refund-policy');
    // The reworded greeting still passes its checks: drift, not failure.
    expect(diff.drifted.single.caseName, 'greeting');
    // The order answer didn't move at all.
    expect(diff.stableCount, 1);

    // ignore: avoid_print
    print(diff.summary());

    expect(() => expectNoRegression(diff), throwsA(isA<RegressionError>()));
  });
}
