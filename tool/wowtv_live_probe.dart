// 한국경제Live(lib/live_service.dart) 진단용. 라이브가 안 잡히면 앱 코드를
// 뜯기 전에 이 스크립트로 어느 단계가 깨졌는지 먼저 가른다.
//   1) 한경 라이브 페이지에서 유튜브 embed videoId 파싱
//   2) InnerTube(ANDROID)로 hlsManifestUrl 획득
//   3) master m3u8에서 최저 대역 변형 선택 + 실제 재생목록 확인
// tool/은 flutter 의존 없이 도는 standalone이라, live_service.dart의 정규식과
// 요청 형태를 그대로 복제해 둔다. 한쪽을 고치면 다른 쪽도 맞출 것.
//
// 사용: dart run tool/wowtv_live_probe.dart
// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';

const String pageUrl =
    'https://www.wowtv.co.kr/LiveCenter/Live/?menuSeq=73918';
const String pageUa =
    'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/131.0 Safari/537.36';
const String playerUa =
    'AppleCoreMedia/1.0.0.22F76 (iPhone; U; CPU OS 18_5 like Mac OS X)';

Future<String?> fetchVideoId(HttpClient client) async {
  final req = await client.getUrl(Uri.parse(pageUrl));
  req.headers.set(HttpHeaders.userAgentHeader, pageUa);
  final resp = await req.close().timeout(const Duration(seconds: 20));
  print('page http=${resp.statusCode}');
  if (resp.statusCode != 200) return null;
  final bytes = await resp.fold<List<int>>(<int>[], (a, c) => a..addAll(c));
  final html = utf8.decode(bytes, allowMalformed: true);
  final m = RegExp(r'youtube\.com/embed/([\w-]{6,})').firstMatch(html);
  final watchCount =
      RegExp(r'youtube\.com/watch\?v=').allMatches(html).length;
  print('page bytes=${html.length} embed=${m?.group(1)} '
      '(참고: 같은 페이지의 VOD watch 링크 $watchCount개는 무시해야 함)');
  return m?.group(1);
}

Future<Map<String, dynamic>?> playerResponse(
    HttpClient client, String videoId) async {
  final uri = Uri.parse(
    'https://www.youtube.com/youtubei/v1/player'
    '?key=AIzaSyB-63vPrdThhKuerbB2N_l7Kwwcxj6yUAc&prettyPrint=false',
  );
  final req = await client.postUrl(uri);
  req.headers.contentType = ContentType.json;
  req.headers.set(HttpHeaders.userAgentHeader,
      'com.google.android.youtube/20.10.38 (Linux; U; Android 14)');
  req.add(utf8.encode(jsonEncode({
    'context': {
      'client': {
        'clientName': 'ANDROID',
        'clientVersion': '20.10.38',
        'androidSdkVersion': 34,
        'hl': 'ko',
        'gl': 'KR',
        'timeZone': 'Asia/Seoul',
        'utcOffsetMinutes': 540,
      },
    },
    'videoId': videoId,
  })));
  final resp = await req.close().timeout(const Duration(seconds: 20));
  print('innertube http=${resp.statusCode}');
  if (resp.statusCode != 200) return null;
  return jsonDecode(await resp.transform(utf8.decoder).join())
      as Map<String, dynamic>;
}

Future<void> main() async {
  final client = HttpClient();
  try {
    final videoId = await fetchVideoId(client);
    if (videoId == null) {
      print('PROBE_FAIL: 페이지에서 embed videoId를 찾지 못함');
      return;
    }

    final json = await playerResponse(client, videoId);
    if (json == null) {
      print('PROBE_FAIL: InnerTube 응답 없음');
      return;
    }
    final details = json['videoDetails'] as Map<String, dynamic>?;
    final playability = json['playabilityStatus'] as Map<String, dynamic>?;
    final hls =
        (json['streamingData'] as Map<String, dynamic>?)?['hlsManifestUrl']
            as String?;
    print('title="${details?['title']}" author="${details?['author']}" '
        'isLive=${details?['isLive']}');
    print('playability=${playability?['status']} '
        'reason="${playability?['reason'] ?? ''}"');
    if (hls == null) {
      print('PROBE_FAIL: hlsManifestUrl 없음 (방송 중이 아니거나 차단)');
      return;
    }

    final req = await client.getUrl(Uri.parse(hls));
    req.headers.set(HttpHeaders.userAgentHeader, playerUa);
    final resp = await req.close().timeout(const Duration(seconds: 20));
    final body = await resp.transform(utf8.decoder).join();
    print('master m3u8 http=${resp.statusCode} bytes=${body.length}');

    final entries = RegExp(r'#EXT-X-STREAM-INF:([^\n]*)\n([^\n#]+)')
        .allMatches(body)
        .map((m) => (
              int.tryParse(
                    RegExp(r'BANDWIDTH=(\d+)').firstMatch(m.group(1)!)?.group(1) ??
                        '',
                  ) ??
                  1 << 30,
              m.group(2)!.trim(),
            ))
        .where((e) => e.$2.startsWith('http'))
        .toList()
      ..sort((a, b) => a.$1.compareTo(b.$1));
    print('variants=${entries.length} '
        'bandwidths=${entries.map((e) => e.$1).toList()}');
    if (entries.isEmpty) {
      print('PROBE_FAIL: 변형 없음');
      return;
    }

    final selected = entries.first;
    final expire =
        RegExp(r'/expire/(\d+)/').firstMatch(selected.$2)?.group(1);
    print('selected bandwidth=${selected.$1} '
        'expire=${expire == null ? "?" : DateTime.fromMillisecondsSinceEpoch(int.parse(expire) * 1000)}');

    final vreq = await client.getUrl(Uri.parse(selected.$2));
    vreq.headers.set(HttpHeaders.userAgentHeader, playerUa);
    final vresp = await vreq.close().timeout(const Duration(seconds: 20));
    final playlist = await vresp.transform(utf8.decoder).join();
    final segments = RegExp(r'#EXTINF:').allMatches(playlist).length;
    print('variant playlist http=${vresp.statusCode} segments=$segments');
    print(vresp.statusCode == 200 && segments > 0
        ? 'PROBE_OK: videoId=$videoId, 재생 가능한 라이브 플레이리스트 확보'
        : 'PROBE_FAIL: 재생목록에 세그먼트가 없음');
  } catch (e, st) {
    print('PROBE_FAIL: $e\n$st');
  } finally {
    client.close();
  }
}
