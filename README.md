# vouch

**Catch silent on-device LLM regressions before your users do.**

You ship an LLM inside your app — flutter_gemma, llama.cpp, MediaPipe, Apple
Foundation Models. Then the model changes under you: a new version, a new
quantization, an OS update that swaps the system model. Same prompts,
different behavior, and **nothing fails loudly**. Practitioners shipping
on-device models put it plainly: *"when the model is updated as part of an OS
update, your prompt can definitely give different output, even when using
greedy sampling."*

Cloud eval tools can't help — they evaluate HTTP endpoints, and your
inference never touches the network. `vouch` closes the gap with three
moves:

1. **Freeze a baseline** of your eval suite under the model you trust.
2. **Diff every later run** against it — after each model swap, quant
   change, or SDK bump.
3. **Gate CI** on what moved: `expectNoRegression(diff)`.

```text
vouch: "support-bot" vs baseline fake-slm 1 (q4) (2026-07-10) — REGRESSED
  model: fake-slm 1 (q4) → fake-slm 2 (q4)
  1 regressed · 1 drifted · 1 stable
  ✗ REGRESSED refund-policy
      is valid JSON: PASS → FAIL (score 1.00 → 0.00) — Unexpected character
      JSON has keys refundDays, requiresReceipt: PASS → FAIL (score 1.00 → 0.00) — not valid JSON
      output: "{"refundDays": 30, "requiresReceipt": true}" → "Sure! Our refund policy lasts 30 days and needs a receipt."
  ~ DRIFTED greeting
      output: "Hello! How can I help you today?" → "Hi there! How can I help you today?"
```

That's real output from [the example](example/): the "upgraded" model
answers a support bot's refund question in friendly prose instead of the
JSON the app parses. No crash, no error — a silently broken feature. vouch
names it, shows both outputs, and fails the build.

## Quickstart

`vouch` builds on
[`llm_replay_eval`](https://pub.dev/packages/llm_replay_eval) — your eval
suite runs through its deterministic record/replay cassettes, so the whole
regression check is offline and byte-stable in CI.

```dart
import 'package:llm_replay_eval/llm_replay_eval.dart';
import 'package:vouch/vouch.dart';

final baselines = BaselineStore('baselines');

test('the on-device model still behaves', () async {
  final report = await mySuite.run(session); // llm_replay_eval

  // First run: freeze the baseline under the model you trust.
  var baseline = baselines.loadOrNull('chat-suite');
  if (baseline == null) {
    baseline = Baseline.fromReport(report,
        model: const ModelInfo(id: 'gemma-3-1b-it', quantization: 'q4'));
    baselines.save(baseline);
  }

  // Every later run — and every model swap — is held to it.
  final diff = compareToBaseline(baseline, report,
      currentModel: const ModelInfo(id: 'gemma-3n-e2b', quantization: 'q4'));

  expectNoRegression(diff); // throws with the full readable diff
});
```

Commit `baselines/` next to your cassettes. Baselines are pretty-printed
JSON, so a re-recorded baseline diffs cleanly in code review — you can see
exactly which frozen outputs a model upgrade was *allowed* to change.

## What lands where

Every case ends up in exactly one bucket — nothing is silently dropped:

| Bucket | Meaning | Fails the gate? |
|---|---|---|
| `regressed` | Passed in the baseline, fails now | **Always** |
| `removed` | Vanished from the suite — coverage shrank | Default (opt out) |
| added & failing | New case the baseline can't vouch for | Default (opt out) |
| `drifted` | Still passes, but output/score changed | Opt in (`failOnDrift`) |
| `stillFailing` | Failed in both, and changed how | No |
| `added` (passing) / `fixed` / stable | Good news | No |

A byte-identical rerun — including known failures frozen in the baseline —
produces **zero findings**. The diff reports movement, not state.

## Built for both readers

`summary()` is for humans in CI logs. `toJson()` is a schema-stable payload
with **full outputs and per-check deltas**, so a coding agent (or a
dashboard) can act on a regression without re-running anything:

```jsonc
{
  "tool": "vouch",
  "formatVersion": 1,
  "suite": "support-bot",
  "counts": { "regressed": 1, "drifted": 1, "stable": 1, "total": 3, /* … */ },
  "findings": [{
    "kind": "regressed",
    "case": "refund-policy",
    "baselinePassed": true,
    "currentPassed": false,
    "outputChanged": true,
    "baselineOutput": "{\"refundDays\": 30, \"requiresReceipt\": true}",
    "currentOutput": "Sure! Our refund policy lasts 30 days and needs a receipt.",
    "checks": [{
      "criterion": "is valid JSON",
      "baselinePassed": true, "currentPassed": false,
      "baselineScore": 1.0, "currentScore": 0.0, "scoreDelta": -1.0,
      "detail": "Unexpected character"
    }, /* … */ ]
  }, /* drifted: greeting … */ ]
}
```

## Comparing candidate models

Baselines are keyed by name, so keeping one per model is one argument:

```dart
baselines.save(gemma3Baseline, name: 'chat-gemma3');
baselines.save(phi4Baseline, name: 'chat-phi4');

// Which upgrade candidate breaks less?
final a = compareToBaseline(baselines.load('chat-gemma3'), candidateReport);
```

Judge scores jitter when run live? `compareToBaseline(..., scoreTolerance:
0.05)` ignores movement inside the band — replayed (cassetted) judges are
deterministic and need no tolerance.

## Scope, honestly

- vouch detects **behavior change relative to a baseline you trusted** — it
  does not judge quality by itself. The judging lives in your
  `llm_replay_eval` checks; vouch makes their verdicts *durable across
  model swaps*.
- Output comparison is exact. In the deterministic replay world of
  cassettes that's a feature; against live nondeterministic inference,
  expect `drifted` noise (that's why drift doesn't fail the gate by
  default).
- A corrupted baseline never degrades silently: every malformed shape
  throws `BaselineFormatException` rather than shrinking your coverage.

Hardened the same way as its siblings: two adversarial audit rounds with
executable probes, 21 confirmed defects fixed, each locked as a regression
test — **85 tests** across the package and its offline example.

## The family

Infrastructure for shipping AI features in Flutter you can actually trust:

| Package | Job |
|---|---|
| [`golden_lens`](https://pub.dev/packages/golden_lens) | Visual regressions an AI agent can act on |
| [`llm_replay_eval`](https://pub.dev/packages/llm_replay_eval) | Deterministic record/replay + evals for on-device LLMs |
| [`redact`](https://pub.dev/packages/redact) | On-device PII redaction around every LLM call |
| **`vouch`** | The regression gate that makes model swaps safe |

MIT licensed. Issues and ideas: [GitHub](https://github.com/Umer9538/vouch).
