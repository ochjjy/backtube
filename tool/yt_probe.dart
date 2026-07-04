// youtube_explode_dart가 현재 유튜브에서 스트림 URL을 뽑을 수 있는지 검증용.
// 백그라운드 오디오가 갑자기 안 나오면 먼저 이 스크립트로 라이브러리가
// 살아있는지 확인할 것. (유튜브 쪽 변경으로 주기적으로 깨진다 → 패키지 업그레이드)
// 사용: dart run tool/yt_probe.dart
// ignore_for_file: avoid_print
import 'dart:io';

import 'package:youtube_explode_dart/youtube_explode_dart.dart';

Future<void> probeManifest(
  YoutubeExplode yt,
  String videoId,
  String label,
  List<YoutubeApiClient>? clients,
) async {
  print('=== $label ===');
  try {
    final manifest = clients == null
        ? await yt.videos.streamsClient.getManifest(videoId)
        : await yt.videos.streamsClient.getManifest(videoId, ytClients: clients);
    final mp4 =
        manifest.audioOnly.where((s) => s.container == StreamContainer.mp4);
    if (mp4.isEmpty) {
      print('PROBE_FAIL($label): no mp4 (iOS playable) audio stream');
      return;
    }
    final selected = mp4.withHighestBitrate();
    print('selected: ${selected.container}/${selected.audioCodec} '
        '${selected.bitrate}');
    print('client(c)=${selected.url.queryParameters['c']}');
    // AVPlayer(iOS)가 보내는 User-Agent로 요청해 실제 재생 환경을 흉내낸다.
    final client = HttpClient();
    client.userAgent =
        'AppleCoreMedia/1.0.0.22F76 (iPhone; U; CPU OS 18_5 like Mac OS X)';
    final req = await client.getUrl(selected.url);
    req.headers.set('Range', 'bytes=0-1023');
    final res = await req.close();
    final bytes = await res.fold<int>(0, (n, chunk) => n + chunk.length);
    client.close();
    print('http status: ${res.statusCode} '
        'content-type: ${res.headers.contentType} bytes=$bytes');
    print(res.statusCode < 400 ? 'PROBE_OK($label)' : 'PROBE_FAIL($label)');
  } catch (e) {
    print('PROBE_FAIL($label): $e');
  }
}

Future<void> main() async {
  final yt = YoutubeExplode();
  try {
    const videoId = String.fromEnvironment('VID', defaultValue: 'dQw4w9WgXcQ');
    final video = await yt.videos.get(videoId);
    print('title: ${video.title}');
    await probeManifest(yt, videoId, 'default', null);
    await probeManifest(yt, videoId, 'ios', [YoutubeApiClient.ios]);
    await probeManifest(
        yt, videoId, 'androidVr', [YoutubeApiClient.androidVr]);
  } catch (e, st) {
    print('PROBE_FAIL: $e\n$st');
  } finally {
    yt.close();
  }
}
