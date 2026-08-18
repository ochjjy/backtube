// requireWatchPage(true/false)가 **다운로드 가능 범위**에 영향을 주는지 확인한다.
// watch 페이지를 함께 받으면 player 요청에 그 페이지의 쿠키·visitorData·STS가
// 실린다(youtube_explode의 video_controller.getPlayerResponse). 그 차이가 첫 1MB
// 이후 403(§2.3.2.1)을 가르는지 보는 것이 목적이다.
// 사용: dart run --define=VID=<videoId> tool/yt_watchpage_probe.dart
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

Future<String> range(Uri url, int from, int to) async {
  final isAndroid = url.queryParameters['c'] == 'ANDROID';
  final target = isAndroid
      ? url
      : url.replace(queryParameters: {
          ...url.queryParameters,
          'range': '$from-$to',
        });
  final client = HttpClient();
  try {
    final r = await client.getUrl(target);
    YoutubeHttpClient.defaultHeaders.forEach(r.headers.set);
    if (isAndroid) r.headers.set('Range', 'bytes=$from-$to');
    final resp = await r.close().timeout(const Duration(seconds: 20));
    final n = await resp.fold<int>(0, (a, c) => a + c.length);
    return 'HTTP ${resp.statusCode} ${n}B';
  } catch (e) {
    return 'ERR $e';
  } finally {
    client.close();
  }
}

Future<void> main() async {
  const videoId = String.fromEnvironment('VID', defaultValue: 'dQw4w9WgXcQ');
  const mb = 1024 * 1024;

  for (final watchPage in [true, false]) {
    print('\n########## requireWatchPage=$watchPage ##########');
    for (final e in <String, YoutubeApiClient?>{
      'ios': YoutubeApiClient.ios,
      'androidVr': YoutubeApiClient.androidVr,
      'android': YoutubeApiClient.android,
      'default': null,
    }.entries) {
      final yt = YoutubeExplode();
      final sw = Stopwatch()..start();
      try {
        final manifest = await yt.videos.streamsClient
            .getManifest(videoId,
                ytClients:
                    e.value == null ? null : [withAudioLanguage(e.value!)],
                requireWatchPage: watchPage)
            .timeout(const Duration(seconds: 30));
        final mp4 =
            manifest.audioOnly.where((s) => s.container == StreamContainer.mp4);
        if (mp4.isEmpty) {
          print('  ${e.key}: mp4 없음');
          continue;
        }
        final a = mp4.withHighestBitrate();
        final ms = sw.elapsedMilliseconds;
        final total = a.size.totalBytes;
        final hasPot = a.url.queryParameters.containsKey('pot');
        // 1조각(0~1MB)과 **2조각(1MB~2MB)** 을 본다. 2조각이 관건이다.
        final c1 = await range(a.url, 0, mb - 1);
        final c2 = total > mb ? await range(a.url, mb, 2 * mb - 1) : '크기부족';
        print('  ${e.key}: ${ms}ms pot=${hasPot ? "있음" : "없음"} '
            'total=${(total / mb).toStringAsFixed(1)}MB | '
            '1조각 $c1 | 2조각 $c2');
      } catch (err) {
        final m = err.toString().replaceAll('\n', ' ');
        print('  ${e.key}: 실패 '
            '${m.length > 80 ? '${m.substring(0, 80)}…' : m}');
      } finally {
        yt.close();
      }
    }
  }
}
