import 'dart:io';
import 'dart:math';

/// Monotonic clock with microsecond resolution.
/// Immune to OS wall-clock NTP adjustments during playback.
class MonotonicClock {
  static final Stopwatch _stopwatch = Stopwatch()..start();

  /// Current local monotonic time in milliseconds (with microsecond precision).
  static double nowMs() => _stopwatch.elapsedMicroseconds / 1000.0;
}

class NtpSample {
  final double rttMs;
  final double offsetMs;
  const NtpSample({required this.rttMs, required this.offsetMs});
}

/// Filters a burst of UDP NTP ping/pong samples by discarding the slowest 60%
/// (which suffered Wi-Fi router queuing spikes) and averaging the fastest 40%.
class ClockSyncFilter {
  final List<NtpSample> _samples = [];
  double _clockOffsetMs = 0.0;
  double _minRttMs = 9999.0;
  bool _isLocked = false;

  double get clockOffsetMs => _clockOffsetMs;
  double get minRttMs => _minRttMs;
  bool get isLocked => _isLocked;
  int get sampleCount => _samples.length;

  void reset() {
    _samples.clear();
    _clockOffsetMs = 0.0;
    _minRttMs = 9999.0;
    _isLocked = false;
  }

  /// Processes a 4-timestamp NTP handshake:
  /// t1: client send time, t2: host receive time, t3: host send time, t4: client receive time.
  void addSample(double t1, double t2, double t3, double t4) {
    final double rtt = (t4 - t1) - (t3 - t2);
    final double offset = ((t2 - t1) + (t3 - t4)) / 2.0;

    // Ignore corrupted or extreme outlier packets
    if (rtt < 0 || rtt > 1500) return;

    _samples.add(NtpSample(rttMs: rtt, offsetMs: offset));
    if (_samples.length > 40) {
      _samples.removeAt(0);
    }

    // Sort ascending by Round-Trip Time (lowest RTT = least Wi-Fi contention)
    final List<NtpSample> sorted = List<NtpSample>.from(_samples)
      ..sort((a, b) => a.rttMs.compareTo(b.rttMs));

    _minRttMs = sorted.first.rttMs;

    // Keep fastest 40% of samples
    final int keepCount = max(1, (sorted.length * 0.4).ceil());
    final Iterable<NtpSample> bestSamples = sorted.take(keepCount);
    final double trimmedMeanOffset =
        bestSamples.fold<double>(0.0, (sum, s) => sum + s.offsetMs) / keepCount;

    if (!_isLocked) {
      _clockOffsetMs = trimmedMeanOffset;
    } else if (rtt <= _minRttMs * 1.35 + 1.5) {
      // Smooth Exponential Moving Average update on low-jitter packets
      _clockOffsetMs = (_clockOffsetMs * 0.75) + (trimmedMeanOffset * 0.25);
    }

    if (_samples.length >= 6) {
      _isLocked = true;
    }
  }

  /// Converts current local monotonic time into the Host phone's clock timeline.
  double estimatedHostNowMs({double hwLatencyOffsetMs = 0.0}) {
    return MonotonicClock.nowMs() + _clockOffsetMs + hwLatencyOffsetMs;
  }
}

/// 3-Zone Phase-Locked Loop (PLL) decision for continuous drift correction.
enum PllZone { deadbandLocked, softPullIn, hardSeek }

class PllDecision {
  final PllZone zone;
  final double errorMs;
  final double targetSpeed;

  const PllDecision({
    required this.zone,
    required this.errorMs,
    required this.targetSpeed,
  });
}

class PllController {
  /// Evaluates phase error e = expectedMs - actualMs:
  /// - |e| < 2.5 ms: Deadband (speed = 1.000x, zero warble)
  /// - 2.5 ms <= |e| <= 45 ms: Proportional speed pull-in (0.965x .. 1.035x, zero click/pop)
  /// - |e| > 45 ms: Hard seek to expected position
  static PllDecision evaluate({
    required double expectedPosMs,
    required double actualPosMs,
  }) {
    final double errorMs = expectedPosMs - actualPosMs;
    final double absError = errorMs.abs();

    if (absError > 45.0) {
      return PllDecision(
        zone: PllZone.hardSeek,
        errorMs: errorMs,
        targetSpeed: 1.0,
      );
    } else if (absError >= 2.5) {
      const double kp = 0.00085;
      final double speed = (1.0 + kp * errorMs).clamp(0.965, 1.035);
      return PllDecision(
        zone: PllZone.softPullIn,
        errorMs: errorMs,
        targetSpeed: speed,
      );
    } else {
      return PllDecision(
        zone: PllZone.deadbandLocked,
        errorMs: errorMs,
        targetSpeed: 1.0,
      );
    }
  }
}

/// Detects the phone's local Wi-Fi IPv4 address (e.g., 192.168.x.x or 10.x.x.x)
/// using pure dart:io without requiring Android location permissions.
Future<String> detectLocalWifiIp() async {
  try {
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLoopback: false,
    );
    String? fallback;
    for (final iface in interfaces) {
      final name = iface.name.toLowerCase();
      final isWifi = name.contains('wlan') ||
          name.contains('wifi') ||
          name.contains('en0') ||
          name.contains('ap') ||
          name.contains('swlan');
      for (final addr in iface.addresses) {
        if (!addr.isLoopback && !addr.address.startsWith('169.254.')) {
          if (isWifi) return addr.address;
          fallback ??= addr.address;
        }
      }
    }
    return fallback ?? '127.0.0.1';
  } catch (_) {
    return '127.0.0.1';
  }
}
