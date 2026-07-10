/// Stands in for a real on-device runtime (flutter_gemma, llama.cpp,
/// Apple Foundation Models…) so the example runs anywhere.
///
/// Version 1 is the model you shipped and trust. Version 2 is the upgrade
/// that *mostly* behaves — it answers the refund question in friendly prose
/// instead of the JSON your app parses. Nothing crashes. That's the point.
class FakeOnDeviceModel {
  FakeOnDeviceModel(this.version);

  /// 1 = the shipped model, 2 = the upgrade.
  final int version;

  Future<String> generate(String prompt) async {
    // A real runtime would stream tokens here.
    await Future<void>.delayed(const Duration(milliseconds: 2));
    if (prompt.contains('refund')) {
      return version == 1
          ? '{"refundDays": 30, "requiresReceipt": true}'
          : 'Sure! Our refund policy lasts 30 days and needs a receipt.';
    }
    if (prompt.contains('Greet')) {
      return version == 1
          ? 'Hello! How can I help you today?'
          : 'Hi there! How can I help you today?';
    }
    return 'Order #123 shipped yesterday and arrives tomorrow.';
  }
}
