# vouch

Catch silent on-device LLM regressions before your users do.

You upgraded the on-device model — new version, new quantization, an OS
update swapped it under you. Same prompts, different behavior, and nothing
failed loudly. `vouch` freezes a **baseline** of your eval suite under the
model you trust, diffs every later run against it, and **fails CI** with
exactly what changed.

```dart
final report = await suite.run(session);            // llm_replay_eval
final baseline = store.load('chat-suite');          // frozen under Gemma 3
final diff = compareToBaseline(baseline, report,
    currentModel: ModelInfo(id: 'gemma-3n-e2b', quantization: 'q4'));

expectNoRegression(diff); // throws with a readable report if anything broke
```

Builds on [`llm_replay_eval`](https://pub.dev/packages/llm_replay_eval)
(deterministic record/replay + evals) and pairs with
[`redact`](https://pub.dev/packages/redact) (on-device PII safety).

**Status: under construction — v0.1.0 in progress.**
