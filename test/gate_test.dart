import 'package:flutter_test/flutter_test.dart';
import 'package:vouch/vouch.dart';

import 'helpers.dart';

void main() {
  const gemma3 = ModelInfo(id: 'gemma-3-1b-it');

  RegressionReport diffOf({
    List<String> regressedCases = const [],
    List<String> removedCases = const [],
    List<String> addedFailingCases = const [],
    List<String> addedPassingCases = const [],
    List<String> driftedCases = const [],
  }) {
    final baseline = Baseline.fromReport(
      reportOf([
        for (final name in regressedCases) caseOf(name, 'old-$name'),
        for (final name in removedCases) caseOf(name, 'old-$name'),
        for (final name in driftedCases) caseOf(name, 'old-$name'),
      ]),
      model: gemma3,
    );
    return compareToBaseline(
      baseline,
      reportOf([
        for (final name in regressedCases)
          caseOf(name, 'new-$name', passed: false),
        for (final name in driftedCases) caseOf(name, 'moved-$name'),
        for (final name in addedFailingCases)
          caseOf(name, 'add-$name', passed: false),
        for (final name in addedPassingCases) caseOf(name, 'add-$name'),
      ]),
    );
  }

  test('a clean diff passes silently', () {
    expect(() => expectNoRegression(diffOf()), returnsNormally);
  });

  test('added passing cases pass the gate', () {
    expect(
      () => expectNoRegression(diffOf(addedPassingCases: ['new'])),
      returnsNormally,
    );
  });

  test('a regression always throws, with the case in the message', () {
    expect(
      () => expectNoRegression(diffOf(regressedCases: ['policy'])),
      throwsA(
        isA<RegressionError>()
            .having((e) => e.message, 'message', contains('1 regressed'))
            .having((e) => e.message, 'message', contains('policy'))
            .having((e) => e.report.hasRegressions, 'report', isTrue),
      ),
    );
  });

  test('removed cases fail by default and can be allowed', () {
    expect(
      () => expectNoRegression(diffOf(removedCases: ['gone'])),
      throwsA(
        isA<RegressionError>().having(
          (e) => e.message,
          'message',
          contains('1 removed'),
        ),
      ),
    );
    expect(
      () => expectNoRegression(
        diffOf(removedCases: ['gone']),
        failOnRemoved: false,
      ),
      returnsNormally,
    );
  });

  test('added failing cases fail by default and can be allowed', () {
    expect(
      () => expectNoRegression(diffOf(addedFailingCases: ['fresh'])),
      throwsA(
        isA<RegressionError>().having(
          (e) => e.message,
          'message',
          contains('1 added-and-failing'),
        ),
      ),
    );
    expect(
      () => expectNoRegression(
        diffOf(addedFailingCases: ['fresh']),
        failOnAddedFailing: false,
      ),
      returnsNormally,
    );
  });

  test('drift passes by default and fails under failOnDrift', () {
    expect(
      () => expectNoRegression(diffOf(driftedCases: ['wobbly'])),
      returnsNormally,
    );
    expect(
      () => expectNoRegression(
        diffOf(driftedCases: ['wobbly']),
        failOnDrift: true,
      ),
      throwsA(
        isA<RegressionError>().having(
          (e) => e.message,
          'message',
          contains('1 drifted'),
        ),
      ),
    );
  });

  test('multiple problems are all named in the message', () {
    expect(
      () => expectNoRegression(
        diffOf(regressedCases: ['r'], removedCases: ['gone']),
      ),
      throwsA(
        isA<RegressionError>()
            .having((e) => e.message, 'message', contains('1 regressed'))
            .having((e) => e.message, 'message', contains('1 removed'))
            .having((e) => e.message, 'message', contains(summaryMarker)),
      ),
    );
  });

  test('the error message embeds the full readable summary', () {
    try {
      expectNoRegression(diffOf(regressedCases: ['policy']));
      fail('should have thrown');
    } on RegressionError catch (e) {
      expect(e.toString(), contains('vouch: "suite" vs baseline'));
      expect(e.toString(), contains('REGRESSED'));
    }
  });
}

const summaryMarker = 'vouch: "suite"';
