import 'package:flutter_test/flutter_test.dart';
import 'package:vouch/vouch.dart';

void main() {
  group('ModelInfo.label', () {
    test('id only', () {
      expect(const ModelInfo(id: 'gemma-3-1b-it').label, 'gemma-3-1b-it');
    });

    test('id and version', () {
      expect(
        const ModelInfo(id: 'gemma-3-1b-it', version: '3.1').label,
        'gemma-3-1b-it 3.1',
      );
    });

    test('everything', () {
      expect(
        const ModelInfo(
          id: 'gemma-3-1b-it',
          version: '3.1',
          quantization: 'q4',
          runtime: 'flutter_gemma 1.2.2',
        ).label,
        'gemma-3-1b-it 3.1 (q4, flutter_gemma 1.2.2)',
      );
    });

    test('quantization without version', () {
      expect(
        const ModelInfo(id: 'phi-4-mini', quantization: 'int8').label,
        'phi-4-mini (int8)',
      );
    });
  });

  group('ModelInfo JSON', () {
    test('toJson omits absent fields', () {
      expect(const ModelInfo(id: 'm').toJson(), {'id': 'm'});
    });

    test('round-trips all fields', () {
      const info = ModelInfo(
        id: 'gemma-3n-e2b',
        version: '2',
        quantization: 'q4',
        runtime: 'flutter_gemma 1.2.2',
        extra: {'device': 'Pixel 9', 'contextLength': 2048},
      );
      final back = ModelInfo.fromJson(info.toJson());
      expect(back.toJson(), info.toJson());
      expect(back.extra['device'], 'Pixel 9');
    });

    test('missing id throws FormatException', () {
      expect(
        () => ModelInfo.fromJson(const {'version': '1'}),
        throwsFormatException,
      );
    });

    test('empty id throws FormatException', () {
      expect(() => ModelInfo.fromJson(const {'id': ''}), throwsFormatException);
    });

    test('wrong-typed optional fields throw FormatException', () {
      expect(
        () => ModelInfo.fromJson(const {'id': 'm', 'version': 3}),
        throwsFormatException,
      );
      expect(
        () => ModelInfo.fromJson(const {'id': 'm', 'runtime': true}),
        throwsFormatException,
      );
      expect(
        () => ModelInfo.fromJson(const {'id': 'm', 'extra': 'nope'}),
        throwsFormatException,
      );
    });
  });
}
