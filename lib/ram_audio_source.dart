import 'dart:typed_data';
import 'package:just_audio/just_audio.dart';

/// Plays an MP3/audio file directly from a [Uint8List] buffer in device RAM.
/// This eliminates flash storage file I/O jitter when starting scheduled playback.
class RamAudioSource extends StreamAudioSource {
  final Uint8List memoryBytes;
  final String contentType;

  RamAudioSource(
    this.memoryBytes, {
    this.contentType = 'audio/mpeg',
    super.tag,
  });

  @override
  Future<StreamAudioResponse> request([int? start, int? end]) async {
    final int effectiveStart = start ?? 0;
    final int effectiveEnd = (end ?? memoryBytes.length).clamp(0, memoryBytes.length);
    final Uint8List slice = Uint8List.sublistView(
      memoryBytes,
      effectiveStart,
      effectiveEnd,
    );

    return StreamAudioResponse(
      sourceLength: memoryBytes.length,
      contentLength: effectiveEnd - effectiveStart,
      offset: effectiveStart,
      stream: Stream.value(slice),
      contentType: contentType,
    );
  }
}
