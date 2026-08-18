// "1KB 검증은 200인데 실제 다운로드는 403" 원인 좁히기.
// 앱과 **완전히 같은 방식**으로 매니페스트를 받은 뒤(youtube_explode, hl=ko,
// requireWatchPage=false), 같은 URL에 대해 요청 모양을 바꿔 가며 상태코드를 잰다.
// 사용: dart run --define=VID=<videoId> tool/yt_range_probe.dart
// ignore_for_file: avoid_print
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

/// [mode]로 요청 모양을 바꿔 가며 상태코드와 받은 바이트를 돌려준다.
Future<String> req(
  Uri baseUrl,
  String mode, {
  required int from,
  required int to,
  String? userAgent,
  bool useHeaderRange = true,
}) async {
  final range = '$from-$to';
  final url = useHeaderRange
      ? baseUrl
      : baseUrl.replace(queryParameters: {
          ...baseUrl.queryParameters,
          'range': range,
        });
  final client = HttpClient();
  try {
    final r = await client.getUrl(url);
    YoutubeHttpClient.defaultHeaders.forEach(r.headers.set);
    if (userAgent != null) r.headers.set('user-agent', userAgent);
    if (useHeaderRange) r.headers.set('Range', 'bytes=$range');
    final resp = await r.close().timeout(const Duration(seconds: 20));
    final n = await resp.fold<int>(0, (a, c) => a + c.length);
    return '$mode → HTTP ${resp.statusCode} ${n}B';
  } catch (e) {
    return '$mode → ERR $e';
  } finally {
    client.close();
  }
}

Future<void> main() async {
  const videoId = String.fromEnvironment('VID', defaultValue: 'dQw4w9WgXcQ');
  const androidUa =
      'com.google.android.youtube/20.10.38 (Linux; U; Android 12) gzip';
  const iosUa =
      'com.google.ios.youtube/20.10.4 (iPhone16,2; U; CPU iOS 18_3_2 like Mac OS X;)';

  final attempts = <String, YoutubeApiClient?>{
    'ios': YoutubeApiClient.ios,
    'androidVr': YoutubeApiClient.androidVr,
    'android': YoutubeApiClient.android,
    'androidSdkless': null, // = 앱의 default 후보
  };

  for (final e in attempts.entries) {
    final yt = YoutubeExplode();
    try {
      final manifest = await yt.videos.streamsClient
          .getManifest(videoId,
              ytClients: e.value == null
                  ? null
                  : [withAudioLanguage(e.value!)],
              requireWatchPage: false)
          .timeout(const Duration(seconds: 30));
      final mp4 =
          manifest.audioOnly.where((s) => s.container == StreamContainer.mp4);
      if (mp4.isEmpty) {
        print('[${e.key}] mp4 오디오 없음');
        continue;
      }
      final audio = mp4.withHighestBitrate();
      final url = audio.url;
      final c = url.queryParameters['c'];
      final total = audio.size.totalBytes;
      final isAndroid = c == 'ANDROID';
      final ua = c != null && c.startsWith('ANDROID') ? androidUa : iosUa;
      print('\n=== ${e.key} (c=$c, size=$total, '
          'header-range=${isAndroid ? "예" : "아니오"}) ===');

      // 1) 앱의 _streamUrlWorks와 동일: 1KB
      print('  ${await req(url, "1KB(검증과 동일)", from: 0, to: 1023, useHeaderRange: isAndroid)}');
      // 2) 앱의 _rangedDownload 첫 조각과 동일: 8MB
      final end8 = total > 8 * 1024 * 1024 ? 8 * 1024 * 1024 : total;
      print('  ${await req(url, "8MB(다운로드와 동일)", from: 0, to: end8 - 1, useHeaderRange: isAndroid)}');
      // 3) 전체 범위 한 번에
      print('  ${await req(url, "전체범위", from: 0, to: total - 1, useHeaderRange: isAndroid)}');
      // 4) range 지정 방식을 반대로
      print('  ${await req(url, "range 방식 반대로", from: 0, to: end8 - 1, useHeaderRange: !isAndroid)}');
      // 5) 클라이언트에 맞는 User-Agent로 8MB
      print('  ${await req(url, "8MB + 클라이언트 UA", from: 0, to: end8 - 1, userAgent: ua, useHeaderRange: isAndroid)}');
    } catch (err) {
      final m = err.toString().replaceAll('\n', ' ');
      print('[${e.key}] 매니페스트 실패: '
          '${m.length > 100 ? '${m.substring(0, 100)}…' : m}');
    } finally {
      yt.close();
    }
  }
}
