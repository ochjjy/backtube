// 저장(saveAudio)을 같은 프로세스에서 연속 수행해 단계별 소요시간을 재고,
// getManifest의 requireWatchPage(기본 true) 유무가 속도/성공률에 주는 영향을
// 비교한다. download_service._resolveAudioStream의 시도 순서·타임아웃을 그대로
// 복제했다(AGENTS.md §4).
// 사용: dart run --define=VID=<videoId> tool/yt_repeat_probe.dart
// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';

import 'package:youtube_explode_dart/youtube_explode_dart.dart';

/// download_service._streamUrlWorks와 같은 요청 형태. 정상 URL을 잘못 튕기지
/// 않는지(거짓 실패) 확인하는 것이 이 검사의 핵심이다.
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
    return 'HTTP ${resp.statusCode} bytes=$bytes c=${audio.url.queryParameters['c']}';
  } catch (e) {
    return 'ERROR $e';
  } finally {
    client.close();
  }
}

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

/// 앱의 saveAudio 1회분. 앱과 동일하게 매번 새 YoutubeExplode를 만들고 닫는다.
Future<void> runOnce(
  int round,
  String videoId, {
  required bool download,
  required bool watchPage,
}) async {
  print('\n########## ROUND $round (requireWatchPage=$watchPage) ##########');
  final sw = Stopwatch()..start();
  int lap() {
    final ms = sw.elapsedMilliseconds;
    sw.reset();
    return ms;
  }

  final yt = YoutubeExplode();
  try {
    final video =
        await yt.videos.get(videoId).timeout(const Duration(seconds: 30));
    print('videos.get: ${lap()}ms  "${video.title}"');

    final attempts = <(String, List<YoutubeApiClient>?)>[
      ('ios', [withAudioLanguage(YoutubeApiClient.ios)]),
      ('androidVr', [withAudioLanguage(YoutubeApiClient.androidVr)]),
      ('default', null),
    ];

    AudioOnlyStreamInfo? picked;
    for (final (label, clients) in attempts) {
      try {
        final manifest = await (clients == null
                ? yt.videos.streamsClient
                    .getManifest(videoId, requireWatchPage: watchPage)
                : yt.videos.streamsClient.getManifest(videoId,
                    ytClients: clients, requireWatchPage: watchPage))
            .timeout(const Duration(seconds: 30));
        final mp4 =
            manifest.audioOnly.where((s) => s.container == StreamContainer.mp4);
        if (mp4.isEmpty) {
          print('manifest[$label]: ${lap()}ms  no mp4 → skip');
          continue;
        }
        final candidate = mp4.withHighestBitrate();
        final ms = lap();
        final check = await checkUrl(candidate);
        print('manifest[$label]: ${ms}ms  OK '
            '${candidate.container.name}/${candidate.audioCodec} '
            '${candidate.bitrate} size=${candidate.size.totalBytes}');
        print('  url check[$label]: $check (${lap()}ms)');
        if (check.startsWith('ERROR') ||
            !RegExp(r'HTTP [23]').hasMatch(check)) {
          print('  → 후보 버리고 다음으로');
          continue;
        }
        picked = candidate;
        break;
      } catch (e) {
        print('manifest[$label]: ${lap()}ms  FAIL $e');
      }
    }
    if (picked == null) {
      print('ROUND $round RESULT: RESOLVE_FAIL (모든 후보 실패)');
      return;
    }
    if (!download) {
      print('ROUND $round RESULT: RESOLVE_OK (다운로드 생략)');
      return;
    }

    var received = 0;
    await for (final chunk in yt.videos.streamsClient.get(picked)) {
      received += chunk.length;
    }
    final ms = lap();
    final kbps = ms > 0 ? (received * 8 / ms).round() : 0;
    print('download: ${ms}ms  received=$received bytes (~$kbps kbit/s)');
    print('ROUND $round RESULT: OK');
  } catch (e) {
    print('ROUND $round RESULT: ERROR after ${lap()}ms → $e');
  } finally {
    yt.close();
  }
}

/// 후보 클라이언트 3종 각각의 스트림 URL이 실제로 살아 있는지 본다.
/// 앱은 첫 성공 후보에서 멈추므로, 뒤쪽 후보(특히 default)의 URL이 403인지는
/// 이 함수로만 드러난다 — 죽은 URL을 고르면 다운로드가 조용히 멈춘다.
Future<void> checkAllClients(String videoId) async {
  print('\n########## 클라이언트별 스트림 URL 생존 확인 ##########');
  final yt = YoutubeExplode();
  try {
    final attempts = <(String, List<YoutubeApiClient>?)>[
      ('ios', [withAudioLanguage(YoutubeApiClient.ios)]),
      ('androidVr', [withAudioLanguage(YoutubeApiClient.androidVr)]),
      ('default', null),
    ];
    for (final (label, clients) in attempts) {
      try {
        final manifest = await (clients == null
                ? yt.videos.streamsClient.getManifest(videoId,
                    requireWatchPage: false)
                : yt.videos.streamsClient.getManifest(videoId,
                    ytClients: clients, requireWatchPage: false))
            .timeout(const Duration(seconds: 30));
        final mp4 =
            manifest.audioOnly.where((s) => s.container == StreamContainer.mp4);
        if (mp4.isEmpty) {
          print('$label: no mp4 → skip');
          continue;
        }
        print('$label: ${await checkUrl(mp4.withHighestBitrate())}');
      } catch (e) {
        print('$label: manifest FAIL $e');
      }
    }
  } finally {
    yt.close();
  }
}

Future<void> main() async {
  const videoId = String.fromEnvironment('VID', defaultValue: 'dQw4w9WgXcQ');
  print('videoId=$videoId');
  await checkAllClients(videoId);
  await runOnce(1, videoId, download: true, watchPage: true);
  await runOnce(2, videoId, download: true, watchPage: true);
  await runOnce(3, videoId, download: true, watchPage: false);
  await runOnce(4, videoId, download: true, watchPage: false);
}
