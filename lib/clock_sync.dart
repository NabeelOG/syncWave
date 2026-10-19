import 'dart:io';
import 'dart:math';

/// Monotonic clock with microsecond resolution.
class MonotonicClock {
  static final Stopwatch _stopwatch = Stopwatch()..start();

  static double nowMs() => _stopwatch.elapsedMicroseconds / 1000.0;
}

class NtpSample {
  final double rttMs;
  final double offsetMs;
  const NtpSample({required this.rttMs, required this.offsetMs});
}

class ClockSyncFilter {
  final List<NtpSample> _samples = [];
  double _clockOffsetMs = 0.0;
  double _minRttMs = 9999.0;
  bool _isLocked = false;

  double get clockOffsetMs => _clockOffsetMs;
  double get minRttMs => _minRttMs;
  bool get isLocked => _isLocked;

  void reset() {
    _samples.clear();
    _clockOffsetMs = 0.0;
    _minRttMs = 9999.0;
    _isLocked = false;
  }

  void addSample(double t1, double t2, double t3, double t4) {
    final double rtt = (t4 - t1) - (t3 - t2);
    final double offset = ((t2 - t1) + (t3 - t4)) / 2.0;

    if (rtt < 0 || rtt > 1500) return;

    _samples.add(NtpSample(rttMs: rtt, offsetMs: offset));
    if (_samples.length > 40) {
      _samples.removeAt(0);
    }

    final List<NtpSample> sorted = List<NtpSample>.from(_samples)
      ..sort((a, b) => a.rttMs.compareTo(b.rttMs));

    _minRttMs = sorted.first.rttMs;

    final int keepCount = max(1, (sorted.length * 0.4).ceil());
    final Iterable<NtpSample> bestSamples = sorted.take(keepCount);
    final double trimmedMeanOffset =
        bestSamples.fold<double>(0.0, (sum, s) => sum + s.offsetMs) / keepCount;

    if (!_isLocked) {
      _clockOffsetMs = trimmedMeanOffset;
    } else if (rtt <= _minRttMs * 1.35 + 1.5) {
      _clockOffsetMs = (_clockOffsetMs * 0.75) + (trimmedMeanOffset * 0.25);
    }

    if (_samples.length >= 4) {
      _isLocked = true;
    }
  }

  double estimatedHostNowMs() {
    return MonotonicClock.nowMs() + _clockOffsetMs;
  }
}

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

/// Returns every usable LAN IPv4 address on this phone, ordered by usefulness.
/// Pure dart:io so there are no extra Android permissions or plugins involved.
Future<List<String>> detectLanIps() async {
  final List<String> wifi = <String>[];
  final List<String> other = <String>[];

  try {
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLoopback: false,
    );

    for (final iface in interfaces) {
      final name = iface.name.toLowerCase();

      // Ignore mobile data, VPN, and virtual tunnels
      if (name.contains('rmnet') ||
          name.contains('ccmni') ||
          name.contains('pdp') ||
          name.contains('clat') ||
          name.contains('tun') ||
          name.contains('tap') ||
          name.contains('dummy') ||
          name.contains('veth')) {
        continue;
      }

      final isWifiLike = name.contains('wlan') ||
          name.contains('wifi') ||
          name.contains('ap') ||
          name.contains('swlan') ||
          name.contains('eth') ||
          name.contains('rndis') ||
          name.contains('p2p');

      for (final addr in iface.addresses) {
        final String ip = addr.address;
        if (addr.isLoopback || ip.startsWith('169.254.')) continue;

        if (isWifiLike) {
          if (!wifi.contains(ip)) wifi.add(ip);
        } else {
          if (!other.contains(ip)) other.add(ip);
        }
      }
    }
  } catch (_) {}

  final List<String> result = [...wifi, ...other];

  // Most common phone hotspot gateways (Android / iPhone / Windows) as last resort
  if (result.isEmpty) {
    result.addAll(const ['192.168.43.1', '192.168.137.1', '172.20.10.1']);
  }
  return result;
}
