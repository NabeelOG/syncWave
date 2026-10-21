import 'dart:io';

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

  /// True when the platform can report an output latency. On iOS there is no
  /// equivalent value yet, so the estimate is 0 and the manual nudge is used.
  static bool get _supported => Platform.isAndroid;

  /// Output latency of this phone in milliseconds (0 if unknown).
  ///
  /// Prefers the *measured* presentation latency (AudioTrack.getTimestamp),
  /// which includes the DSP path, and falls back to the HAL buffer estimate.
  static Future<double> outputLatencyMs() async {
    if (!_supported) return 0.0;
    try {
      final double measured =
          await _channel.invokeMethod<double>('measuredLatencyMs') ?? 0.0;
      if (measured.isFinite && measured > 0) return measured;

      final double estimate =
          await _channel.invokeMethod<double>('outputLatencyMs') ?? 0.0;
      return estimate.isFinite && estimate > 0 ? estimate : 0.0;
    } catch (_) {
      return 0.0;
    }
  }

  /// Manual per-device nudge in milliseconds (persisted on the device).
  static Future<int> nudgeMs() async {
    if (!_supported) return 0;
    try {
      return await _channel.invokeMethod<int>('getOffsetMs') ?? 0;
    } catch (_) {
      return 0;
    }
  }

  static Future<void> setNudgeMs(int value) async {
    if (!_supported) return;
    try {
      await _channel.invokeMethod<void>('setOffsetMs', {'value': value});
    } catch (_) {}
  }
}
