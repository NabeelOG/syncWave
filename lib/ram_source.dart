import 'dart:typed_data';

import 'package:just_audio/just_audio.dart';

/// Plays audio straight from a byte buffer held in RAM.
/// Avoids flash-storage I/O jitter when playback starts.
class RamSource extends StreamAudioSource {
  final Uint8List bytes;
  final String contentType;

  RamSource(this.bytes, {this.contentType = 'audio/mpeg', super.tag});

  @override
  Future<StreamAudioResponse> request([int? start, int? end]) async {
    final from = start ?? 0;
    final to = (end ?? bytes.length).clamp(0, bytes.length);
    return StreamAudioResponse(
      sourceLength: bytes.length,
      contentLength: to - from,
      offset: from,
      stream: Stream.value(Uint8List.sublistView(bytes, from, to)),
      contentType: contentType,
    );
  }
}

/// Maps a file extension to the matching audio content type.
String audioContentType(String fileName) {
  final ext = fileName.toLowerCase().split('.').last;
  switch (ext) {
    case 'wav':
      return 'audio/wav';
    case 'm4a':
    case 'aac':
      return 'audio/mp4';
    case 'ogg':
      return 'audio/ogg';
    default:
      return 'audio/mpeg';
  }
}
