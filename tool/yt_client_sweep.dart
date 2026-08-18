// InnerTube 클라이언트 11종을 한 번에 훑어, 각각 (1) 매니페스트가 나오는지
// (2) mp4(=iOS 재생 가능) 오디오가 있는지 (3) 그 URL이 실제로 살아 있는지를 잰다.
// 봇 확인·로그인 요구에 막혔을 때 "어느 클라이언트로 우회되는지" 찾는 용도.
// 사용: dart run --define=VID=<videoId> tool/yt_client_sweep.dart
// ignore_for_file: avoid_print, deprecated_member_use
import 'dart:convert';
import 'dart:io';

import 'package:youtube_explode_dart/youtube_explode_dart.dart';

YoutubeApiClient withAudioLanguage(YoutubeApiClient base, [String lang = 'ko']) {
  final payload = json.decode(json.encode(base.payload)) as Map<String, dynamic>;
  final client = payload['context']?['client'];
  if (client is Map) client['hl'] = lang;
  return YoutubeApiClient(
    payload,
    base.apiUrl,
    headers: {...base.headers, 'accept-language': '$lang,en;q=0.5'},
  );
}

Future<String> checkUrl(AudioOnlyStreamInfo audio) async {
  final isAndroid = audio.url.queryParameters['c'] == 'ANDROID';
  final url = isAndroid
      ? audio.url
      : audio.url.replace(queryParameters: {
          ...audio.url.queryParameters,
          'range': '0-1023',
        });
  final client = HttpClient();
  try {
    final req = await client.getUrl(url);
    YoutubeHttpClient.defaultHeaders.forEach(req.headers.set);
    if (isAndroid) req.headers.set('Range', 'bytes=0-1023');
    final resp = await req.close().timeout(const Duration(seconds: 10));
    final bytes = await resp.fold<int>(0, (n, c) => n + c.length);
    return 'HTTP ${resp.statusCode} (${bytes}B)';
  } catch (e) {
    return 'ERR $e';
  } finally {
    client.close();
  }
}

Future<void> main() async {
  const videoId = String.fromEnvironment('VID', defaultValue: 'dQw4w9WgXcQ');
  final candidates = <String, YoutubeApiClient>{
    'ios': YoutubeApiClient.ios,
    'androidVr': YoutubeApiClient.androidVr,
    'android': YoutubeApiClient.android,
    'androidSdkless': YoutubeApiClient.androidSdkless,
    'androidMusic': YoutubeApiClient.androidMusic,
    'safari(WEB)': YoutubeApiClient.safari,
    'mweb': YoutubeApiClient.mweb,
    'tv': YoutubeApiClient.tv,
    'tvSimplyEmbedded': YoutubeApiClient.tvSimplyEmbedded,
    'mediaConnect': YoutubeApiClient.mediaConnect,
    'webCreator': YoutubeApiClient.webCreator,
  };

  print('videoId=$videoId  (mp4=iOS 재생 가능 컨테이너)');
  print('${'client'.padRight(18)} | ${'manifest'.padRight(9)} | '
      '${'mp4'.padRight(4)} | url');
  print('-' * 78);

  for (final entry in candidates.entries) {
    final yt = YoutubeExplode();
    final sw = Stopwatch()..start();
    try {
      final manifest = await yt.videos.streamsClient
          .getManifest(videoId,
              ytClients: [withAudioLanguage(entry.value)],
              requireWatchPage: false)
          .timeout(const Duration(seconds: 30));
      final mp4 =
          manifest.audioOnly.where((s) => s.container == StreamContainer.mp4);
      final ms = sw.elapsedMilliseconds;
      if (mp4.isEmpty) {
        print('${entry.key.padRight(18)} | ${'OK'.padRight(9)} | '
            '${'없음'.padRight(4)} | (${ms}ms) 오디오 mp4 없음');
        continue;
      }
      final check = await checkUrl(mp4.withHighestBitrate());
      print('${entry.key.padRight(18)} | ${'OK'.padRight(9)} | '
          '${'있음'.padRight(4)} | $check (${ms}ms)');
    } catch (e) {
      final msg = e.toString().replaceAll('\n', ' ');
      print('${entry.key.padRight(18)} | ${'FAIL'.padRight(9)} | '
          '${'-'.padRight(4)} | ${msg.length > 90 ? '${msg.substring(0, 90)}…' : msg}');
    } finally {
      yt.close();
    }
  }
}
