import 'dart:convert';
import 'dart:io';

import 'baseline.dart';

/// Loads and saves [Baseline]s as JSON files on disk.
///
/// Baselines are written as pretty-printed JSON so they diff cleanly in code
/// review — a reviewer can see exactly which frozen outputs changed when a
/// baseline is re-recorded. Files are named `<name>.baseline.json` inside
/// [directory].
///
/// This is the only part of the package that touches dart:io, keeping the
/// rest pure and unit-testable.
class BaselineStore {
  BaselineStore(this.directory);

  /// Directory holding baseline files (created on save if absent).
  final String directory;

  static const String _suffix = '.baseline.json';
  static const JsonEncoder _encoder = JsonEncoder.withIndent('  ');

  /// The path a baseline with [name] would occupy.
  ///
  /// Throws [ArgumentError] if [name] contains a path separator — the
  /// default file key is the suite name, which the store must never let
  /// escape [directory] or crash on.
  String pathFor(String name) {
    if (name.contains('/') || name.contains('\\')) {
      throw ArgumentError.value(
        name,
        'name',
        'must not contain a path separator; pass an explicit safe name to '
            'save/load instead',
      );
    }
    return '$directory${Platform.pathSeparator}$name$_suffix';
  }

  /// Loads the baseline named [name].
  ///
  /// Unlike a cassette, a missing baseline is never treated as empty — an
  /// empty reference would make every case look "added" and let a broken
  /// model sail through CI. Throws a [StateError] telling you to record one
  /// first, or [BaselineFormatException] if the file is malformed.
  Baseline load(String name) {
    final baseline = loadOrNull(name);
    if (baseline == null) {
      throw StateError(
        'No baseline named "$name" in $directory. Run the suite against a '
        'model you trust and save one with BaselineStore.save first.',
      );
    }
    return baseline;
  }

  /// Loads the baseline named [name], or null if no file exists yet.
  Baseline? loadOrNull(String name) {
    final file = File(pathFor(name));
    if (!file.existsSync()) return null;
    final Object? decoded;
    try {
      decoded = jsonDecode(file.readAsStringSync());
    } on FormatException catch (e) {
      // Truncated write, merge-conflict markers, plain corruption — surface
      // it as the documented exception type instead of a raw parse error.
      throw BaselineFormatException(
        'Baseline file ${file.path} is not valid JSON: ${e.message}',
      );
    }
    if (decoded is! Map<String, Object?>) {
      throw BaselineFormatException(
        'Baseline file ${file.path} is not a JSON object.',
      );
    }
    return Baseline.fromJson(decoded);
  }

  /// Persists [baseline] to disk, creating [directory] if needed.
  ///
  /// The file is keyed by [name] when given, else by the baseline's suite
  /// name — pass a name to keep per-model baselines side by side.
  ///
  /// Throws [ArgumentError] if the baseline can't be represented as JSON
  /// (e.g. a non-JSON value in `ModelInfo.extra`).
  void save(Baseline baseline, {String? name}) {
    final path = pathFor(name ?? baseline.suiteName);
    final String encoded;
    try {
      encoded = _encoder.convert(baseline.toJson());
    } on JsonUnsupportedObjectError catch (e) {
      throw ArgumentError(
        'Baseline for "${baseline.suiteName}" contains a non-JSON value '
        '(${e.unsupportedObject.runtimeType}) — ModelInfo.extra may only '
        'hold JSON-encodable values.',
      );
    }
    final dir = Directory(directory);
    if (!dir.existsSync()) dir.createSync(recursive: true);
    File(path).writeAsStringSync('$encoded\n');
  }

  /// Whether a baseline file for [name] already exists.
  bool exists(String name) => File(pathFor(name)).existsSync();
}
