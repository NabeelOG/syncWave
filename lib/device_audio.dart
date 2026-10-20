import 'package:flutter/services.dart';

/// Access to the parts of the audio path that Flutter cannot see directly.
///
/// [outputLatencyMs] is the delay between the player emitting a sample and the
/// sound leaving the speaker. Two phones with a 20 ms difference in this value
/// sound out of sync even when their players are perfectly aligned, so the
/// difference is compensated for when the start time is scheduled.
///
/// [nudgeMs] is a manual, per-device correction (in milliseconds) that the user
/// can trim by ear. Positive values make this phone start earlier.
class DeviceAudio {
  static const MethodChannel _channel = MethodChannel('syncwave/device');

  /// Estimated output latency of this phone in milliseconds (0 if unknown).
  static Future<double> outputLatencyMs() async {
    try {
      final double value =
          await _channel.invokeMethod<double>('outputLatencyMs') ?? 0.0;
      return value.isFinite && value > 0 ? value : 0.0;
    } catch (_) {
      return 0.0;
    }
  }

  /// Manual per-device nudge in milliseconds (persisted on the device).
  static Future<int> nudgeMs() async {
    try {
      return await _channel.invokeMethod<int>('getOffsetMs') ?? 0;
    } catch (_) {
      return 0;
    }
  }

  static Future<void> setNudgeMs(int value) async {
    try {
      await _channel.invokeMethod<void>('setOffsetMs', {'value': value});
    } catch (_) {}
  }
}
