import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';

import 'player_service.dart';

/// 라이브를 들을 수 없는 사유를 사용자에게 그대로 보여주기 위한 예외.
/// toString()이 메시지 자체라 UI에 "Exception:" 접두어가 붙지 않는다.
/// (download_service.dart의 AudioUnavailableException과 같은 의도)
class LiveUnavailableException implements Exception {
  final String message;

  const LiveUnavailableException(this.message);

  @override
  String toString() => message;
}

/// 라이브 한 건의 재생 정보.
class LiveStreamInfo {
  final String videoId;
  final String title;
  final String author;
  final String? thumbUrl;

  /// 실제로 재생할 HLS 플레이리스트(최저 대역 변형).
  final Uri playlistUrl;

  /// 스트림 URL 만료 시각(파싱 가능하면). 만료 전에 재발급해야 한다.
  final DateTime? expiresAt;

  const LiveStreamInfo({
    required this.videoId,
    required this.title,
    required this.author,
    required this.thumbUrl,
    required this.playlistUrl,
    required this.expiresAt,
  });

  MediaItem toMediaItem() => MediaItem(
        id: videoId,
        title: title,
        artist: author.isEmpty ? '한국경제TV' : author,
        // 라이브는 길이가 없다(duration=null) → 잠금화면도 진행바 대신 라이브 표시.
        artUri: (thumbUrl != null && thumbUrl!.isNotEmpty)
            ? Uri.parse(thumbUrl!)
            : null,
      );
}

/// 한국경제TV 라이브 페이지에서 유튜브 라이브 영상 id를 파싱하고, 그 라이브의
/// HLS 오디오 스트림 주소를 얻는다. **웹뷰 없이 HTML만 내려받아 처리한다.**
///
/// 유튜브 라이브는 저장(progressive/DASH) 경로가 아예 발행되지 않아
/// download_service의 매니페스트 방식으로는 아무 스트림도 얻을 수 없고,
/// HLS만 나온다. 그래서 이 경로는 별도로 존재한다.
class WowtvLive {
  static const String pageUrl =
      'https://www.wowtv.co.kr/LiveCenter/Live/?menuSeq=73918';

  // 모바일 UA로 요청하면 m.wowtv.co.kr로 리다이렉트된다. 두 페이지 모두 같은
  // embed 구조지만, 리다이렉트를 한 번 줄이려고 데스크톱 UA를 쓴다.
  static const String _pageUa =
      'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/131.0 Safari/537.36';

  // AVPlayer가 보내는 UA. 매니페스트를 실제 재생 환경과 같은 조건으로 받는다.
  static const String _playerUa =
      'AppleCoreMedia/1.0.0.22F76 (iPhone; U; CPU OS 18_5 like Mac OS X)';

  /// 라이브 재생에 필요한 모든 정보를 한 번에 확보한다.
  static Future<LiveStreamInfo> resolve() async {
    final videoId = await _fetchLiveVideoId();
    debugPrint('[BT] live: videoId=$videoId');

    final json = await _playerResponse(videoId);
    final details = json['videoDetails'] as Map<String, dynamic>?;
    final playability = json['playabilityStatus'] as Map<String, dynamic>?;
    final streaming = json['streamingData'] as Map<String, dynamic>?;
    final hls = streaming?['hlsManifestUrl'] as String?;
    final status = playability?['status'] as String?;
    final reason = (playability?['reason'] as String?) ?? '';
    debugPrint('[BT] live: status=$status reason="$reason" '
        'isLive=${details?['isLive']} hls=${hls != null}');

    if (hls == null) {
      // isLive=true인데 hls가 없으면 방송 준비/전환 중이거나 차단된 상태다.
      if (details?['isLive'] == true) {
        throw const LiveUnavailableException(
          '라이브 스트림을 아직 받을 수 없습니다.\n잠시 후 다시 시도해 주세요.',
        );
      }
      throw LiveUnavailableException(
        '지금은 라이브 방송이 진행 중이 아닙니다.'
        '${reason.isEmpty ? '' : '\n($reason)'}',
      );
    }

    final playlist = await _pickLowestBitrateVariant(hls);
    return LiveStreamInfo(
      videoId: videoId,
      title: (details?['title'] as String?) ?? '한국경제TV LIVE',
      author: (details?['author'] as String?) ?? '한국경제TV',
      thumbUrl: _thumbnailOf(details),
      playlistUrl: playlist,
      expiresAt: _expiryOf(playlist),
    );
  }

  /// 라이브 페이지에서 유튜브 영상 id를 뽑는다.
  ///
  /// 라이브 플레이어는 `<div class="videowrap">` 안의 유튜브 embed iframe이다.
  /// 같은 페이지에 VOD 클립 `watch?v=` 링크가 수십 개, 그리고 주석 처리된 옛
  /// live_chat id까지 들어 있으므로 **embed 주소만** 집어야 엉뚱한 영상을
  /// 재생하지 않는다.
  static Future<String> _fetchLiveVideoId() async {
    final client = HttpClient();
    try {
      final req = await client.getUrl(Uri.parse(pageUrl));
      req.headers.set(HttpHeaders.userAgentHeader, _pageUa);
      final resp = await req.close().timeout(const Duration(seconds: 20));
      if (resp.statusCode != 200) {
        throw LiveUnavailableException(
          '한국경제TV 페이지를 불러오지 못했습니다 (HTTP ${resp.statusCode}).',
        );
      }
      final bytes = await resp.fold<List<int>>(<int>[], (acc, c) => acc..addAll(c));
      final html = utf8.decode(bytes, allowMalformed: true);
      final m = RegExp(r'youtube\.com/embed/([\w-]{6,})').firstMatch(html);
      if (m == null) {
        throw const LiveUnavailableException(
          '라이브 방송 주소를 찾지 못했습니다.\n'
          '(페이지 구조가 바뀌었을 수 있습니다)',
        );
      }
      return m.group(1)!;
    } on SocketException catch (e) {
      throw LiveUnavailableException('네트워크에 연결할 수 없습니다.\n$e');
    } finally {
      client.close();
    }
  }

  /// InnerTube player를 ANDROID 컨텍스트로 직접 호출해 HLS 매니페스트를 얻는다.
  ///
  /// ‼️ 저장/일반 재생 경로(download_service)는 ios 클라이언트를 우선하지만,
  /// **라이브에서는 ios가 "동영상이 처리 중입니다"로 거부**하고 WEB/MWEB/TVHTML5도
  /// 각각 재생불가·새로고침 요구·봇 확인으로 막힌다. 실측상 ANDROID만
  /// hlsManifestUrl을 내려준다. 순서를 ios 우선으로 "통일"하지 말 것.
  static Future<Map<String, dynamic>> _playerResponse(String videoId) async {
    final client = HttpClient();
    try {
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
      if (resp.statusCode != 200) {
        throw LiveUnavailableException(
          '유튜브 응답이 올바르지 않습니다 (HTTP ${resp.statusCode}).',
        );
      }
      final body = await resp.transform(utf8.decoder).join();
      return jsonDecode(body) as Map<String, dynamic>;
    } on SocketException catch (e) {
      throw LiveUnavailableException('네트워크에 연결할 수 없습니다.\n$e');
    } finally {
      client.close();
    }
  }

  /// master 플레이리스트에서 **가장 낮은 대역폭 변형**을 고른다.
  ///
  /// 유튜브 라이브 HLS에는 오디오 전용 렌디션(EXT-X-MEDIA)이 없고 모든 변형이
  /// 영상+오디오로 묶여 있다. master를 그대로 넘기면 플레이어가 화질을 올려
  /// 수 Mbps를 쓰므로, 오디오만 들을 이 앱에서는 최저 변형(144p·약 270kbps,
  /// 오디오 64k HE-AAC)으로 고정해 데이터를 아낀다. 음질을 올리고 싶으면
  /// 이 선택을 360p 변형(오디오 128k AAC-LC, 약 1Mbps)으로 바꾸면 된다.
  static Future<Uri> _pickLowestBitrateVariant(String masterUrl) async {
    final client = HttpClient();
    try {
      final req = await client.getUrl(Uri.parse(masterUrl));
      req.headers.set(HttpHeaders.userAgentHeader, _playerUa);
      final resp = await req.close().timeout(const Duration(seconds: 20));
      if (resp.statusCode != 200) {
        debugPrint('[BT] live: master m3u8 status=${resp.statusCode}, '
            'master URL 그대로 사용');
        return Uri.parse(masterUrl);
      }
      final body = await resp.transform(utf8.decoder).join();
      final entries = RegExp(r'#EXT-X-STREAM-INF:([^\n]*)\n([^\n#]+)')
          .allMatches(body)
          .map((m) => (
                int.tryParse(
                      RegExp(r'BANDWIDTH=(\d+)')
                              .firstMatch(m.group(1)!)
                              ?.group(1) ??
                          '',
                    ) ??
                    1 << 30,
                m.group(2)!.trim(),
              ))
          .where((e) => e.$2.startsWith('http'))
          .toList();
      if (entries.isEmpty) {
        debugPrint('[BT] live: 변형을 찾지 못함, master URL 그대로 사용');
        return Uri.parse(masterUrl);
      }
      entries.sort((a, b) => a.$1.compareTo(b.$1));
      debugPrint('[BT] live: variants=${entries.length} '
          'selected bandwidth=${entries.first.$1}');
      return Uri.parse(entries.first.$2);
    } catch (e) {
      debugPrint('[BT] live: 변형 선택 실패($e), master URL 그대로 사용');
      return Uri.parse(masterUrl);
    } finally {
      client.close();
    }
  }

  /// 잠금화면 아트워크용 썸네일. 데이터 절약을 위해 최대 해상도(maxres, 수백 KB)
  /// 대신 **가로 320px 이상 중 가장 작은 것**을 고른다(잠금화면에는 충분하다).
  static String? _thumbnailOf(Map<String, dynamic>? details) {
    final list = (details?['thumbnail'] as Map<String, dynamic>?)?['thumbnails'];
    if (list is! List || list.isEmpty) return null;
    final items = list.cast<Map<String, dynamic>>().toList()
      ..sort((a, b) =>
          ((a['width'] as int?) ?? 0).compareTo((b['width'] as int?) ?? 0));
    final pick = items.firstWhere(
      (t) => ((t['width'] as int?) ?? 0) >= 320,
      orElse: () => items.last,
    );
    return pick['url'] as String?;
  }

  /// googlevideo URL의 `/expire/<epoch>/`를 읽는다. 실측 약 6시간짜리.
  static DateTime? _expiryOf(Uri url) {
    final m = RegExp(r'/expire/(\d+)/').firstMatch(url.toString());
    final seconds = int.tryParse(m?.group(1) ?? '');
    if (seconds == null) return null;
    return DateTime.fromMillisecondsSinceEpoch(seconds * 1000);
  }
}

/// 라이브 재생을 시작하고, 백그라운드에서 오래 켜 둬도 끊기지 않게 유지한다.
///
/// 유지해야 하는 두 가지:
/// 1. 스트림 URL 만료(약 6시간) — 만료 10분 전에 새 매니페스트로 교체한다.
/// 2. 네트워크 전환/일시 장애로 인한 재생 오류 — 백오프를 두고 재발급·재개.
///
/// 저장파일 재생이 시작되면(btPlaybackOrigin != live) 스스로 물러난다.
/// 공유 플레이어를 남의 재생 위에 덮어쓰지 않기 위한 규칙이다(AGENTS.md §2.1).
class LiveSession {
  LiveSession._();

  static final LiveSession instance = LiveSession._();

  static const List<Duration> _backoff = [
    Duration(seconds: 3),
    Duration(seconds: 10),
    Duration(seconds: 30),
    Duration(minutes: 1),
    Duration(minutes: 3),
  ];

  Timer? _refreshTimer;
  StreamSubscription<PlayerState>? _stateSub;
  LiveStreamInfo? _current;
  int _retry = 0;
  bool _busy = false;

  bool get isActive =>
      _current != null && btPlaybackOrigin == BtPlaybackOrigin.live;

  LiveStreamInfo? get current => _current;

  /// 라이브를 해석해 재생을 시작한다. 실패하면 예외를 던진다(호출부에서 안내).
  Future<LiveStreamInfo> start() async {
    stop();
    final info = await WowtvLive.resolve();
    await _load(info, play: true);
    _attachRecovery();
    return info;
  }

  /// 재생/정지 토글.
  ///
  /// 라이브는 정지해 둔 사이에도 방송이 계속 흘러가고, HLS 재생목록의 라이브
  /// 윈도우(실측 3초)가 지나가 버리면 그대로 재개할 수 없다. 그래서 잠깐
  /// 멈춘 것이면 그냥 play, 오래 멈췄으면 매니페스트를 새로 받아 지금 시점의
  /// 방송으로 다시 붙는다.
  static const Duration _staleAfter = Duration(seconds: 20);
  DateTime? _pausedAt;

  Future<void> togglePlay() async {
    if (btPlayer.playing) {
      btPlayIntent = false;
      _pausedAt = DateTime.now();
      await btPlayer.pause();
      return;
    }

    btPlayIntent = true;
    final pausedAt = _pausedAt;
    final stale = pausedAt == null ||
        DateTime.now().difference(pausedAt) > _staleAfter;
    _pausedAt = null;
    if (!isActive) {
      // 세션이 끝났거나(재시도 한도 초과) 다른 재생이 끼어든 상태 → 처음부터.
      await start();
      return;
    }
    if (!stale) {
      // play()는 재생이 끝날 때 완료되는 Future다(_load 주석 참고) → await 금지.
      unawaited(btPlayer.play());
      return;
    }
    debugPrint('[BT] live: 정지가 길어 매니페스트를 새로 받아 재개');
    await _refresh(reason: 'resume');
  }

  /// 재생을 멈추고 유지 타이머/구독을 모두 정리한다.
  void stop() {
    _refreshTimer?.cancel();
    _refreshTimer = null;
    _stateSub?.cancel();
    _stateSub = null;
    _current = null;
    _retry = 0;
  }

  Future<void> _load(LiveStreamInfo info, {required bool play}) async {
    final session = await AudioSession.instance;
    // 재생 직전에 세션을 활성화한다(AGENTS.md §2.5).
    await session.setActive(true);

    await btPlayer.stop();
    await btPlayer.setShuffleModeEnabled(false);
    await btPlayer.setLoopMode(LoopMode.off);
    // 라이브는 배속 재생이 의미 없고(계속 따라잡아야 함) 버퍼만 흔든다.
    await btPlayer.setSpeed(1.0);
    // 소스 종류를 URL 확장자 추측에 맡기지 않고 HLS로 명시한다.
    // (변형 플레이리스트 URL에는 .m3u8 확장자가 없을 수 있다)
    await btPlayer.setAudioSource(
      HlsAudioSource(info.playlistUrl, tag: info.toMediaItem()),
    );
    btPlaybackOrigin = BtPlaybackOrigin.live;
    _current = info;
    debugPrint('[BT] live: loaded "${info.title}" expires=${info.expiresAt}');

    if (play) {
      btPlayIntent = true;
      // ‼️ just_audio의 play()가 반환하는 Future는 "재생이 시작될 때"가 아니라
      // **재생이 끝나거나 일시정지/정지될 때** 완료된다. 라이브는 끝나지 않으므로
      // await 하면 이 함수가 영영 반환되지 않는다(진행 팝업이 안 닫히고,
      // _refresh의 _busy가 풀리지 않아 만료 갱신도 멈춘다). 시작만 걸고 넘어간다.
      unawaited(btPlayer.play());
    }
    _scheduleRefresh(info.expiresAt);
  }

  /// 만료 10분 전에 매니페스트를 재발급한다. 만료 시각을 모르면 3시간 주기.
  void _scheduleRefresh(DateTime? expiresAt) {
    _refreshTimer?.cancel();
    var delay = const Duration(hours: 3);
    if (expiresAt != null) {
      delay = expiresAt.difference(DateTime.now()) - const Duration(minutes: 10);
      if (delay < const Duration(minutes: 1)) delay = const Duration(minutes: 1);
    }
    debugPrint('[BT] live: 다음 갱신까지 ${delay.inMinutes}분');
    _refreshTimer = Timer(delay, () => _refresh(reason: 'expire'));
  }

  void _attachRecovery() {
    _stateSub?.cancel();
    _stateSub = btPlayer.playerStateStream.listen(
      (state) {
        if (!isActive) return;
        // 라이브가 끝나거나 스트림이 끊기면 completed로 떨어진다. 방송이
        // 계속 중일 수도 있으므로(전환·일시 장애) 백오프를 두고 재시도한다.
        if (state.processingState == ProcessingState.completed) {
          debugPrint('[BT] live: 스트림 종료 감지 → 재연결 시도');
          _scheduleRetry('completed');
        } else if (state.playing &&
            state.processingState == ProcessingState.ready) {
          _retry = 0;
        }
      },
      onError: (Object e, StackTrace st) {
        debugPrint('[BT] live: player error $e');
        _scheduleRetry('error');
      },
    );
  }

  void _scheduleRetry(String reason) {
    if (!isActive || _busy) return;
    if (_retry >= _backoff.length) {
      debugPrint('[BT] live: 재시도 한도 초과 → 중단');
      stop();
      return;
    }
    final delay = _backoff[_retry++];
    debugPrint('[BT] live: $reason → ${delay.inSeconds}초 후 재연결 (#$_retry)');
    _refreshTimer?.cancel();
    _refreshTimer = Timer(delay, () => _refresh(reason: reason));
  }

  Future<void> _refresh({required String reason}) async {
    if (_busy) return;
    // 그 사이 저장파일 재생이 시작됐으면 공유 플레이어를 건드리지 않는다.
    if (!isActive) {
      debugPrint('[BT] live: 다른 재생이 시작됨 → 세션 종료');
      stop();
      return;
    }
    _busy = true;
    try {
      final wasPlaying = btPlayer.playing || btPlayIntent;
      debugPrint('[BT] live: 매니페스트 갱신($reason) wasPlaying=$wasPlaying');
      final info = await WowtvLive.resolve();
      if (!isActive) return;
      await _load(info, play: wasPlaying);
    } catch (e) {
      debugPrint('[BT] live: 갱신 실패 $e');
      _scheduleRetry('refresh-failed');
    } finally {
      _busy = false;
    }
  }
}
