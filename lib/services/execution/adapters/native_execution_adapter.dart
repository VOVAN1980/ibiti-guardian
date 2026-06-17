import 'package:ibiti_guardian/models/send_native_models.dart';

abstract class NativeExecutionAdapter {
  Future<SendNativeQuote> quoteNative(SendNativeRequest request);
  Future<SendNativeResult> sendNative(SendNativeRequest request);
}
