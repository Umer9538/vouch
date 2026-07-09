/// Identifies the model (and runtime) an eval run was produced with, so a
/// regression report can say exactly what changed between two runs — e.g.
/// `gemma-3-1b-it (q4) → gemma-3n-e2b (q4)`.
class ModelInfo {
  const ModelInfo({
    required this.id,
    this.version,
    this.quantization,
    this.runtime,
    this.extra = const {},
  });

  /// Parses the JSON produced by [toJson].
  ///
  /// Throws a [FormatException] if the required `id` field is missing or not
  /// a string.
  factory ModelInfo.fromJson(Map<String, Object?> json) {
    final id = json['id'];
    if (id is! String || id.isEmpty) {
      throw const FormatException(
        'ModelInfo JSON must have a non-empty string "id" field.',
      );
    }
    final version = json['version'];
    final quantization = json['quantization'];
    final runtime = json['runtime'];
    final extra = json['extra'];
    if (version is! String? || quantization is! String? || runtime is! String?) {
      throw FormatException(
        'ModelInfo "$id" has a non-string version/quantization/runtime.',
      );
    }
    if (extra is! Map<String, Object?>?) {
      throw FormatException('ModelInfo "$id" has a non-object "extra".');
    }
    return ModelInfo(
      id: id,
      version: version,
      quantization: quantization,
      runtime: runtime,
      extra: extra ?? const {},
    );
  }

  /// Model identifier, e.g. `gemma-3-1b-it` or `apple-foundation-3b`.
  final String id;

  /// Model version, e.g. `3.1` or an OS build the model shipped with.
  final String? version;

  /// Quantization label, e.g. `q4`, `int8`, `2bpw-qat`.
  final String? quantization;

  /// The inference runtime and its version, e.g. `flutter_gemma 1.2.2`.
  final String? runtime;

  /// Anything else worth pinning (device model, context length, seed…).
  final Map<String, Object?> extra;

  /// Compact human-readable label, e.g.
  /// `gemma-3-1b-it 3.1 (q4, flutter_gemma 1.2.2)`.
  String get label {
    final head = [id, if (version != null) version].join(' ');
    final parens = [
      if (quantization != null) quantization,
      if (runtime != null) runtime,
    ].join(', ');
    return parens.isEmpty ? head : '$head ($parens)';
  }

  Map<String, Object?> toJson() => {
    'id': id,
    if (version != null) 'version': version,
    if (quantization != null) 'quantization': quantization,
    if (runtime != null) 'runtime': runtime,
    if (extra.isNotEmpty) 'extra': extra,
  };

  @override
  String toString() => 'ModelInfo($label)';
}
