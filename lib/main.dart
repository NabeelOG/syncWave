import 'package:audio_session/audio_session.dart';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';

import 'client.dart';
import 'host.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final session = await AudioSession.instance;
  await session.configure(const AudioSessionConfiguration.music());
  runApp(const SyncWaveApp());
}

class SyncWaveApp extends StatelessWidget {
  const SyncWaveApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SyncWave',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true).copyWith(
        scaffoldBackgroundColor: const Color(0xFF0B0E17),
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF6366F1),
          brightness: Brightness.dark,
        ),
      ),
      home: const HomeScreen(),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  final TextEditingController _name =
      TextEditingController(text: 'Phone ${100 + DateTime.now().millisecond % 900}');

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final ip = _ipFromRoute(
      WidgetsBinding.instance.platformDispatcher.defaultRouteName,
    );
    if (ip != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _openClient(ip));
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _name.dispose();
    super.dispose();
  }

  @override
  void didPushRoute(Route<dynamic> route) {
    final ip = _ipFromRoute(route.settings.name ?? '');
    if (ip != null) _openClient(ip);
  }

  /// Extracts the host IP from a `syncwave://join?ip=1.2.3.4` link.
  String? _ipFromRoute(String route) {
    if (!route.startsWith('syncwave://')) return null;
    final uri = Uri.tryParse(route);
    final ip = uri?.queryParameters['ip'];
    if (ip == null || ip.isEmpty) return null;
    return ip;
  }

  void _openClient(String ip) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ClientScreen(
          deviceName: _name.text.trim().isEmpty ? 'Friend' : _name.text.trim(),
          autoJoinIp: ip,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                width: 78,
                height: 78,
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [Color(0xFF6366F1), Color(0xFF10B981)],
                  ),
                  borderRadius: BorderRadius.circular(24),
                ),
                child: const Icon(
                  Icons.speaker_group_rounded,
                  size: 42,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 20),
              const Text(
                'SyncWave',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 32,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Play one song on every phone at the same time.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 15, color: Colors.white60),
              ),
              const SizedBox(height: 34),
              TextField(
                controller: _name,
                decoration: InputDecoration(
                  labelText: 'Your Name',
                  prefixIcon: const Icon(Icons.person_outline_rounded),
                  filled: true,
                  fillColor: const Color(0xFF151926),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(16),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
              const SizedBox(height: 20),
              SizedBox(
                height: 60,
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF6366F1),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(18),
                    ),
                  ),
                  onPressed: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => HostScreen(
                          deviceName: _name.text.trim().isEmpty
                              ? 'Host'
                              : _name.text.trim(),
                        ),
                      ),
                    );
                  },
                  icon: const Icon(Icons.qr_code_2_rounded, size: 26),
                  label: const Text(
                    'Host a Party',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                height: 60,
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    backgroundColor: const Color(0xFF151926),
                    side: const BorderSide(color: Colors.white24),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(18),
                    ),
                  ),
                  onPressed: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => ClientScreen(
                          deviceName: _name.text.trim().isEmpty
                              ? 'Friend'
                              : _name.text.trim(),
                        ),
                      ),
                    );
                  },
                  icon: const Icon(Icons.group_rounded, size: 26),
                  label: const Text(
                    'Join a Party',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
