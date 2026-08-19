import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

import 'yt_audio_language.dart';

/// 저장 불가 사유를 사용자에게 그대로 보여주기 위한 예외.
/// toString()이 메시지 자체라 UI에 "Exception:" 접두어가 붙지 않는다.
class AudioUnavailableException implements Exception {
  final String message;

  /// 처리 중·봇 확인처럼 시간이 지나면 성공할 수 있는 경우 true.
  final bool retryable;

  /// 봇 확인/로그인 요구로 막힌 경우 true. 이때만 웹뷰 세션 우회를 시도한다
  /// (다른 사유는 세션을 바꿔도 결과가 같다).
  final bool botBlocked;

  const AudioUnavailableException(
    this.message, {
    this.retryable = false,
    this.botBlocked = false,
  });

  @override
  String toString() => message;
}

/// 스트림 URL이 403을 돌려줬다는 내부 신호(사용자에게 보이지 않는다).
/// 재시도해도 같은 결과이므로, 받는 쪽은 URL 자체를 갈아타야 한다.
class _StreamForbidden implements Exception {
  const _StreamForbidden();

  @override
  String toString() => 'stream forbidden (403)';
}

/// 앱 밖(웹뷰 세션)에서 해석해 온 오디오 스트림.
///
/// 유튜브가 봇 확인을 걸면 앱의 InnerTube 요청은 어떤 클라이언트로도 막히지만,
/// 앱이 띄워 둔 유튜브 웹뷰는 정상 브라우징으로 이미 그 확인을 통과한 세션이다.
/// 그 세션 안에서 player를 직접 호출해 얻은 결과를 이 형태로 받아 다운로드만
/// 앱이 수행한다. (요청 경로는 main.dart의 `_resolveViaWebView` 참고)
class ResolvedAudioStream {
  final Uri url;

  /// 전체 크기. 모르면 0(진행률은 불확정으로 표시된다).
  final int sizeBytes;
  final String mimeType;

  /// 어느 클라이언트 컨텍스트로 받아냈는지(로그용).
  final String via;

  /// player 응답의 `videoDetails`. watch 페이지 조회가 rate limit에 걸렸을 때
  /// 제목·저자·길이를 메울 대체 출처가 된다.
  final String? title;
  final String? author;
  final Duration? duration;

  const ResolvedAudioStream({
    required this.url,
    required this.sizeBytes,
    required this.mimeType,
    required this.via,
    this.title,
    this.author,
    this.duration,
  });
}

/// 사용자가 저장을 취소했을 때. 실패가 아니므로 호출부는 에러 안내 대신
/// "취소했습니다"만 보여준다.
class DownloadCancelledException implements Exception {
  const DownloadCancelledException();

  @override
  String toString() => '저장을 취소했습니다';
}

/// 저장 취소 신호. 진행 팝업의 "취소"가 [cancel]을 부르면 [DownloadService.saveAudio]가
/// 다음 확인 지점(스트림 해석 전후, 청크 수신마다)에서 받다 만 `.part`를 지우고
/// [DownloadCancelledException]을 던진다.
///
/// 확인 지점 사이의 긴 네트워크 대기(매니페스트 요청은 타임아웃 30초)는 중간에
/// 끊지 못하므로, UI는 취소를 누른 즉시 팝업을 닫고 뒷정리는 이 토큰에 맡긴다.
class DownloadCancelToken {
  bool _cancelled = false;

  bool get isCancelled => _cancelled;

  void cancel() => _cancelled = true;
}

/// 로컬에 저장된 오디오 한 건의 메타데이터.
class SavedAudio {
  final String videoId;
  final String title;
  final String author;
  final Duration? duration;
  final String filePath;

  /// 로컬에 저장된 썸네일 파일 경로(있으면). 잠금화면/목록 아트워크용.
  final String? thumbPath;

  /// 원격 썸네일 URL(사이드카에 저장). 로컬 파일이 없을 때 폴백.
  final String? thumbUrl;

  const SavedAudio({
    required this.videoId,
    required this.title,
    required this.author,
    required this.duration,
    required this.filePath,
    this.thumbPath,
    this.thumbUrl,
  });
}

/// 유튜브 오디오를 기기에 m4a(AAC)로 저장하고, 저장된 목록을 관리한다.
///
/// 온디바이스 MP3 트랜스코딩은 대용량 네이티브 코덱(ffmpeg)이 필요해
/// 비현실적이므로, 유튜브 원본 오디오 스트림(mp4/AAC)을 그대로 저장한다.
class DownloadService {
  /// `getManifest(requireWatchPage:)`에 넘길 값. **true로 둘 것(패키지 기본값).**
  ///
  /// 한때 false로 바꿨었다. watch 페이지는 서명 챌린지를 풀 JS 솔버가 있을 때만
  /// 쓰이는데 이 앱은 솔버 없이 `YoutubeExplode()`를 만드니 낭비로 보였고, 실제로
  /// 매니페스트가 1752~2055ms → 877~917ms로 빨라졌다(2026-08-17 실측).
  ///
  /// **되돌렸다.** 그 뒤로 저장이 아예 안 됐다. watch 페이지를 함께 받으면 player
  /// 요청에 그 페이지의 쿠키·visitorData·STS가 실린다(youtube_explode의
  /// `video_controller.getPlayerResponse`). 그게 빠지면 유튜브가 세션을 신뢰하지
  /// 않아 스트림 URL이 §2.3.2.1의 "첫 1MB만" 제한에 걸리는 것으로 보인다.
  /// 1초 아끼려고 저장을 깨뜨릴 이유는 없다.
  static const bool _requireWatchPage = true;

  /// 다운로드 중 데이터가 이만큼 끊기면 실패로 본다. 느린 회선의 정상적인
  /// 지연과 구분되도록 넉넉히 잡되, 무한 대기는 되지 않게 한다.
  static const Duration _stallTimeout = Duration(seconds: 45);

  /// range 요청 한 조각의 크기(1MB). **더 키우지 말 것.**
  ///
  /// 유튜브가 한 요청에 내주는 양에 상한이 있다 — 실측(2026-08-18, 두 영상 ×
  /// ANDROID/IOS 모두 동일): `bytes=0-1048575`(1MB) 206, `bytes=0-1199999`(1.2MB)
  /// **403**. 예전에 8MB로 두었다가 저장이 통째로 실패했다. 3.4MB짜리 짧은
  /// 영상에서는 조각이 전체 크기로 줄어들어 우연히 통과해 문제가 안 보였다.
  static const int _chunkSize = 1024 * 1024;

  /// 한 조각을 다시 시도하는 최대 횟수. 받은 지점부터 이어 받는다.
  static const int _chunkRetries = 3;

  /// **합본(progressive itag 18)을 먼저 받는다.**
  ///
  /// 유튜브가 오디오 전용 포맷에 PO token을 요구하면서(§2.3.2.1) 저장 대상 영상
  /// 대부분이 첫 1MB에서 403이 된다. 그때마다 오디오 전용 후보들을 훑느라
  /// 1MB씩 헛되이 받고 10초 이상을 쓴다. itag 18은 토큰 없이 끝까지 받아지므로
  /// (§2.3.2.4) 그쪽을 먼저 시도해 저장을 빠르고 확실하게 만든다.
  ///
  /// 대가: 영상이 섞여 있어 용량이 늘 수 있고(말하는 사람 위주 뉴스는 오히려
  /// 더 작다 — 15분 VOA 기준 합본 13.3MB vs 오디오 전용 14.8MB), 오디오가
  /// 96~128kbps로 오디오 전용(132kbps)보다 낮을 수 있다(실측 §2.3.2.4).
  ///
  /// false로 되돌리면 예전처럼 오디오 전용을 먼저 시도한다. 유튜브가 토큰
  /// 요구를 거둬들이면 그렇게 바꿀 것.
  static const bool _preferMuxed = true;

  /// 웹뷰 안에서 받을 때의 조각 크기(1MB). base64로 실려 오므로 실제 메시지는
  /// 약 1.33MB가 된다. 더 키우면 JS 채널 한 번에 오가는 문자열이 커져 위험하다.
  static const int _webViewChunkSize = 1024 * 1024;

  static const String _folder = 'saved_audio';

  static Future<Directory> _dir() async {
    final base = await getApplicationDocumentsDirectory();
    final dir = Directory('${base.path}/$_folder');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  /// 저장 루트(folder==null) 또는 그 하위 서브폴더 디렉터리. 없으면 생성.
  static Future<Directory> _folderDir(String? folder) async {
    final root = await _dir();
    if (folder == null || folder.isEmpty) return root;
    final dir = Directory('${root.path}/$folder');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  /// 폴더 이름에서 경로 구분자/특수문자 제거. 서브폴더는 1단계만 허용.
  static String sanitizeFolderName(String name) {
    var n = name.trim().replaceAll(RegExp(r'[/\\:*?"<>|]'), '_');
    n = n.replaceAll(RegExp(r'^\.+'), ''); // 숨김/상위경로 방지
    return n.trim();
  }

  static Future<bool> folderExists(String name) async {
    final root = await _dir();
    return Directory('${root.path}/$name').exists();
  }

  static Future<void> createFolder(String name) async {
    final root = await _dir();
    final dir = Directory('${root.path}/$name');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
  }

  /// 루트 아래 서브폴더 이름 목록(이름 오름차순).
  static Future<List<String>> listFolders() async {
    final root = await _dir();
    final result = <String>[];
    await for (final e in root.list()) {
      if (e is Directory) {
        result.add(e.path.split('/').where((s) => s.isNotEmpty).last);
      }
    }
    result.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return result;
  }

  /// 폴더 안의 오디오(.m4a) 파일 개수.
  static Future<int> folderFileCount(String folder) async {
    final dir = await _folderDir(folder);
    var n = 0;
    await for (final e in dir.list()) {
      if (e is File && e.path.endsWith('.m4a')) n++;
    }
    return n;
  }

  /// 폴더와 그 안의 모든 파일을 삭제한다.
  static Future<void> deleteFolder(String folder) async {
    final root = await _dir();
    final dir = Directory('${root.path}/$folder');
    if (await dir.exists()) {
      await dir.delete(recursive: true);
    }
  }

  /// videoId의 m4a/json/jpg를 from 폴더에서 to 폴더로 이동한다.
  static Future<void> move(
    String videoId, {
    String? from,
    String? to,
  }) async {
    final src = await _folderDir(from);
    final dst = await _folderDir(to);
    if (src.path == dst.path) return;
    for (final ext in ['.m4a', '.json', '.jpg']) {
      final f = File('${src.path}/$videoId$ext');
      if (await f.exists()) {
        await f.rename('${dst.path}/$videoId$ext');
      }
    }
  }

  static Future<File> _audioFile(String videoId) async {
    final dir = await _dir();
    return File('${dir.path}/$videoId.m4a');
  }

  static Future<File> _metaFile(String videoId) async {
    final dir = await _dir();
    return File('${dir.path}/$videoId.json');
  }

  static Future<File> _thumbFile(String videoId) async {
    final dir = await _dir();
    return File('${dir.path}/$videoId.jpg');
  }

  /// 루트뿐 아니라 서브폴더로 옮겨진 파일도 "저장됨"으로 본다(중복 다운로드 방지).
  static Future<bool> isSaved(String videoId) async {
    if (await (await _audioFile(videoId)).exists()) return true;
    for (final folder in await listFolders()) {
      final dir = await _folderDir(folder);
      if (await File('${dir.path}/$videoId.m4a').exists()) return true;
    }
    return false;
  }

  /// 썸네일을 로컬에 내려받아 경로를 반환한다. 실패하면 null.
  static Future<String?> _downloadThumbnail(String videoId, String url) async {
    if (url.isEmpty) return null;
    final client = HttpClient();
    try {
      final req = await client.getUrl(Uri.parse(url));
      final resp = await req.close().timeout(const Duration(seconds: 15));
      if (resp.statusCode != 200) {
        debugPrint('[BT] thumb download status=${resp.statusCode}');
        return null;
      }
      final file = await _thumbFile(videoId);
      await resp.pipe(file.openWrite());
      debugPrint('[BT] thumb saved: ${file.path}');
      return file.path;
    } catch (e) {
      debugPrint('[BT] thumb download failed: $e');
      return null;
    } finally {
      client.close();
    }
  }

  /// 지정한 videoId의 오디오를 다운로드해 저장한다.
  /// [onBytes]는 (받은 바이트, 전체 바이트) — 전체를 모르면 total=0.
  /// [onStage]는 첫 바이트가 오기 전 단계 표시("준비 중"이 길어질 때 어디서
  /// 걸렸는지 사용자와 로그 양쪽에 보이게 한다).
  /// [cancelToken]이 취소되면 받다 만 `.part`를 지우고 [DownloadCancelledException].
  /// 유튜브가 이 기기를 막았을 때의 우회 경로 두 가지(둘 다 웹뷰 세션을 쓴다):
  /// [resolveViaWebView]는 스트림 URL을 웹뷰 세션으로 받아 오고,
  /// [downloadChunkViaWebView]는 **다운로드 자체를 웹뷰 안에서** 수행한다
  /// (앱의 HTTP 요청이 통째로 403인 기기용. §2.3.3)
  static Future<SavedAudio> saveAudio(
    String videoId, {
    void Function(int received, int total)? onBytes,
    void Function(String stage)? onStage,
    DownloadCancelToken? cancelToken,
    Future<ResolvedAudioStream?> Function(String videoId, {int expectSize})?
        resolveViaWebView,
    Future<List<int>?> Function(Uri url, int from, int to)?
        downloadChunkViaWebView,
  }) async {
    void throwIfCancelled() {
      if (cancelToken?.isCancelled ?? false) {
        throw const DownloadCancelledException();
      }
    }

    final sw = Stopwatch()..start();
    int lap() {
      final ms = sw.elapsedMilliseconds;
      sw.reset();
      return ms;
    }

    final yt = YoutubeExplode();
    try {
      debugPrint('[BT] download start videoId=$videoId');
      throwIfCancelled();
      onStage?.call('영상 정보 확인 중...');

      // 메타 조회(`yt.videos.get`)는 **의도적으로 하지 않는다.** 그건 watch
      // 페이지를 긁는 요청이라 유튜브 rate limit에 가장 먼저 걸리고(실측: 이것만
      // 429가 나면서 11초를 잡아먹었다), 그 요청이 IP 평판을 깎아 정작 중요한
      // 스트림 URL까지 403으로 만든다. 필요한 건 전부 더 싼 출처로 얻는다:
      //   제목/저자 → oEmbed(_titleViaOembed), 길이 → 스트림 URL의 dur 파라미터,
      //   썸네일 → i.ytimg.com 고정 규칙. (§2.3.4)
      AudioOnlyStreamInfo? audio;
      ResolvedAudioStream? viaWebView;
      if (!_preferMuxed) {
        try {
          audio = await _resolveAudioStream(yt, videoId, onStage: onStage);
        } on AudioUnavailableException catch (e) {
          // 봇 확인·rate limit으로 막힌 경우에만 웹뷰 세션으로 한 번 더. 다른
          // 사유(비공개, 처리 중 등)는 세션을 바꿔도 결과가 같으므로 그대로 올린다.
          if (!e.botBlocked || resolveViaWebView == null) rethrow;
          debugPrint('[BT] download: 차단 감지 → 웹뷰 세션 우회 시도');
          onStage?.call('웹뷰 세션으로 다시 시도 중...');
          throwIfCancelled();
          viaWebView = await resolveViaWebView(videoId);
          if (viaWebView == null) rethrow;
          debugPrint('[BT] download: 웹뷰 세션 우회 성공 via=${viaWebView.via} '
              'size=${viaWebView.sizeBytes} mime=${viaWebView.mimeType}');
        }
        debugPrint('[BT] download.t: manifest=${lap()}ms');
      }

      throwIfCancelled();
      onStage?.call('다운로드 시작 대기 중...');
      var sourceUrl = viaWebView?.url ?? audio?.url ?? Uri.parse('about:blank');
      var total = viaWebView?.sizeBytes ?? audio?.size.totalBytes ?? 0;
      if (viaWebView == null && audio != null) {
        // 참고: 명목 비트레이트로 계산한 예상 길이. 실제 스트림 길이와 비교용.
        final approxSeconds = audio.bitrate.bitsPerSecond > 0
            ? (total * 8 / audio.bitrate.bitsPerSecond).round()
            : 0;
        debugPrint('[BT] download stream ${audio.container.name}/'
            '${audio.audioCodec} ${audio.bitrate} size=$total bytes '
            '(~${approxSeconds ~/ 60}:${(approxSeconds % 60).toString().padLeft(2, '0')} '
            'at nominal bitrate)');
      }

      final file = await _audioFile(videoId);
      // 다운로드 중 앱이 죽어도 반쪽짜리 파일이 목록에 뜨지 않게 .part로 받고
      // 완료 후 원자적으로 rename 한다.
      final tmp = File('${file.path}.part');

      // 유튜브가 PO token 없는 URL에 **첫 1MB만** 주는 제약(§2.3.2.1) 때문에,
      // 후보 하나가 1MB에서 403으로 끊기는 일이 흔하다. 그때 포기하지 않고
      // **다음 후보 URL로 갈아타며** 끝까지 시도한다. 실기기 실측(2026-08-18):
      // androidVr URL은 완주, android URL은 매번 1MB에서 403.
      final sources = <(String, Future<ResolvedAudioStream?> Function())>[
        if (audio != null)
          ('매니페스트', () async => ResolvedAudioStream(
                url: audio!.url,
                sizeBytes: audio.size.totalBytes,
                mimeType: audio.container.name,
                via: 'manifest',
              )),
        // 합본 itag18: 토큰 없이 끝까지 받아지는 유일한 포맷(§2.3.2.4).
        // _preferMuxed면 맨 앞에서 시도해 헛된 1MB 시도를 없앤다.
        if (_preferMuxed)
          ('합본 itag18', () => _viaInnerTube(videoId, 'muxed18', _ctxAndroid,
              muxed: true)),
        // 웹뷰가 **재생 중인 미디어 URL**을 잡아 뒀다면 그게 가장 확실하다
        // (서명·n·PO token이 이미 유효).
        if (resolveViaWebView != null)
          // 기대 크기를 넘겨 준다. 피드 인라인 재생으로 잡힌 미디어 URL이
          // 이 영상 것인지 확인하는 유일한 근거다(§2.3.3).
          ('웹뷰 세션', () => resolveViaWebView(videoId, expectSize: total)),
        // 패키지가 비디오 스트림 HEAD 403 때문에 버린 클라이언트를 직접 살린다.
        ('직접 androidVr', () => _viaInnerTube(videoId, 'androidVr', _ctxAndroidVr)),
        ('직접 ios', () => _viaInnerTube(videoId, 'ios', _ctxIos)),
        // _preferMuxed가 false일 때의 마지막 보루.
        if (!_preferMuxed)
          ('합본 itag18', () => _viaInnerTube(videoId, 'muxed18', _ctxAndroid,
              muxed: true)),
      ];

      var received = 0;
      var done = false;
      // 첫 1MB만 받고 403이 나면 PO token 제한이다(§2.3.2.1).
      //
      // 이때 **어느 클라이언트가 막혔는지**(URL의 `c=` 값)만 기억한다. 예전에는
      // 한 번 막히면 토큰 없는 후보를 전부 건너뛰었는데, 제한은 (클라이언트 ×
      // 영상 × 세션)마다 걸리는 것이라 **다른 클라이언트가 되는 영상까지 놓쳤다**
      // (리스트에서 되던 저장이 안 되게 된 원인). 같은 클라이언트만 건너뛴다.
      final cappedClients = <String>{};
      String clientOf(Uri u) => u.queryParameters['c'] ?? '?';
      ResolvedAudioStream? lastSource = viaWebView;
      // 이미 웹뷰로 해석해 둔 것이 있으면 그것부터.
      final ordered = viaWebView != null
          ? [('웹뷰 세션(선해석)', () async => viaWebView), ...sources]
          : sources;

      for (final (label, resolve) in ordered) {
        throwIfCancelled();
        final src = await resolve();
        if (src == null) continue;
        // 같은 클라이언트가 이미 1MB에서 막혔고 토큰도 없으면 결과가 같다.
        // 사용자가 직접 재생해서 잡힌 URL(MEDIA*)은 실제 재생 세션에서 나온
        // 것이라 성질이 다를 수 있으므로 언제나 한 번은 받아 본다.
        final fromPlayback = src.via.startsWith('MEDIA');
        // itag 18(합본)은 같은 ANDROID 클라이언트로 받지만 **제한 대상이
        // 아니다** — 오디오 전용 포맷만 토큰을 요구한다(§2.3.2.4). 클라이언트가
        // 막혔다는 이유로 건너뛰면 이 마지막 보루를 잃는다.
        final isMuxed = src.via.contains('muxed');
        final client = clientOf(src.url);
        if (!fromPlayback &&
            !isMuxed &&
            cappedClients.contains(client) &&
            !src.url.toString().contains('pot=')) {
          debugPrint('[BT] download: [$label] $client는 이미 1MB에서 막힘 → 건너뜀');
          lastSource ??= src;
          continue;
        }
        lastSource = src;
        sourceUrl = src.url;
        if (src.sizeBytes > 0) total = src.sizeBytes;
        // 제목/저자/길이를 들고 온 후보면 메타 출처로 삼는다(§2.3.4).
        if (src.title != null && (viaWebView == null || viaWebView.title == null)) {
          viaWebView = src;
        }
        debugPrint('[BT] download: 시도 [$label] size=$total');
        onStage?.call(isMuxed ? '다운로드 중...' : '다운로드 중 ($label)...');
        try {
          received = await _downloadToFile(
            tmp,
            sourceUrl,
            total,
            onBytes: onBytes,
            cancelToken: cancelToken,
          );
          done = true;
          break;
        } on _StreamForbidden {
          if (received == 0) cappedClients.add(clientOf(sourceUrl));
          debugPrint('[BT] download: [$label] 403으로 중단 → 다음 후보 '
              '(막힌 클라이언트: ${cappedClients.join(",")})');
        }
      }

      // 앱의 HTTP 요청이 어느 URL로도 안 되면 마지막으로 **웹뷰 안에서** 받는다.
      // 토큰이 붙어 있거나, 사용자가 직접 재생해서 잡힌 URL일 때만 의미가 있다
      // (그 외에는 웹뷰에서 받아도 똑같이 1MB에서 막히는 것을 실측했다).
      if (!done &&
          downloadChunkViaWebView != null &&
          lastSource != null &&
          (lastSource.url.toString().contains('pot=') ||
              lastSource.via.startsWith('MEDIA'))) {
        throwIfCancelled();
        debugPrint('[BT] download: 모든 후보 403 → 웹뷰 안에서 직접 받기');
        onStage?.call('웹뷰에서 받는 중...');
        sourceUrl = lastSource.url;
        if (lastSource.sizeBytes > 0) total = lastSource.sizeBytes;
        try {
          received = await _downloadToFile(
            tmp,
            sourceUrl,
            total,
            onBytes: onBytes,
            cancelToken: cancelToken,
            fetchChunk: downloadChunkViaWebView,
          );
          done = true;
        } on _StreamForbidden {
          debugPrint('[BT] download: 웹뷰 안에서도 403');
        }
      }

      if (!done) {
        // _preferMuxed면 매니페스트 해석을 건너뛰므로 여기서 사유를 묻는다.
        // (비공개·삭제·라이브 처리 중 등은 안내가 달라야 한다. §3)
        final diagnosis = await _diagnoseUnavailable(videoId);
        if (diagnosis != null) throw diagnosis;
        throw const AudioUnavailableException(
          '유튜브가 이 영상의 스트림을 내주지 않습니다.\n'
          '잠시 후 다시 시도해 주세요.',
          retryable: true,
          botBlocked: true,
        );
      }
      debugPrint('[BT] download finished received=$received bytes');

      if (cancelToken?.isCancelled ?? false) {
        // 받다 만 .part는 남기지 않는다(재개 기능이 없어 쓸모가 없다).
        try {
          await tmp.delete();
        } catch (_) {}
        debugPrint('[BT] download cancelled videoId=$videoId '
            'received=$received/$total');
        throw const DownloadCancelledException();
      }

      if (received == 0) {
        try {
          await tmp.delete();
        } catch (_) {}
        throw Exception('다운로드된 데이터가 없습니다 (스트림이 비어 있음)');
      }

      if (await file.exists()) {
        await file.delete();
      }
      await tmp.rename(file.path);

      // 메타는 다운로드가 끝난 뒤에 채운다. 순서가 중요하다 — 먼저 하면 그
      // 요청들이 rate limit을 건드려 정작 스트림을 못 받는다.
      // 제목/저자: 웹뷰 응답(있으면) → oEmbed → videoId.
      var title = viaWebView?.title;
      var author = viaWebView?.author;
      if (title == null || title.isEmpty) {
        final oembed = await _titleViaOembed(videoId);
        title = oembed?.$1;
        author ??= oembed?.$2;
      }
      title = (title == null || title.isEmpty) ? videoId : title;
      // 길이: 스트림 URL의 dur 파라미터(초, 소수점 있음)로 **요청 없이** 얻는다.
      // 잠금화면 길이와 androidVr 2배 보정(§3)에 쓰이므로 비워 두면 안 된다.
      final duration = _durationFromUrl(sourceUrl) ?? viaWebView?.duration;
      // 썸네일 URL은 규칙이 고정이라 어떤 API도 거치지 않는다(rate limit 무관).
      final thumbUrl = 'https://i.ytimg.com/vi/$videoId/hqdefault.jpg';
      final thumbPath = await _downloadThumbnail(videoId, thumbUrl);
      debugPrint('[BT] download meta: title="$title" author="$author" '
          'duration=$duration');

      final meta = SavedAudio(
        videoId: videoId,
        title: title,
        author: author ?? '',
        duration: duration,
        filePath: file.path,
        thumbPath: thumbPath,
        thumbUrl: thumbUrl,
      );
      await (await _metaFile(videoId)).writeAsString(jsonEncode({
        'videoId': videoId,
        'title': title,
        'author': author ?? '',
        'durationMs': duration?.inMilliseconds,
        'thumbUrl': thumbUrl,
      }));
      debugPrint('[BT] download saved: ${file.path}');
      return meta;
    } finally {
      yt.close();
    }
  }

  /// 다운로드 가능한 오디오 스트림을 찾는다. ios 스트림이 iOS AVPlayer 재생과
  /// 가장 잘 맞으므로 저장 파일도 ios를 우선 시도하고, ios 매니페스트가 403이면
  /// androidVr·default 순으로 폴백한다.
  static Future<AudioOnlyStreamInfo> _resolveAudioStream(
    YoutubeExplode yt,
    String videoId, {
    void Function(String stage)? onStage,
  }) async {
    // hl을 한국어로 덮어 자동 더빙 영상이 영어 더빙이 아닌 한국어(원본)
    // 오디오를 내려주게 한다. (원인/배경은 yt_audio_language.dart 참고)
    //
    // 후보를 늘려 봐야 소용없는지는 실측으로 확인했다(2026-08-17,
    // tool/yt_client_sweep.dart): 패키지가 제공하는 11종 중 매니페스트가 나오는
    // 것은 ios·androidVr·android·androidSdkless 넷뿐이고, 나머지(safari/mweb/
    // tv/tvSimplyEmbedded/webCreator/mediaConnect/androidMusic)는 봇 확인이
    // 걸리지 않은 IP에서도 전부 실패한다. 즉 **클라이언트 추가는 봇 확인
    // 우회책이 못 된다.** 아래 넷이 사실상 전부다.
    // **androidVr가 첫 번째다.** 이 클라이언트만 PO token 없이도 전체 다운로드가
    // 되는 URL을 준다(실기기 2026-08-18: androidVr로 14.8MB 완주, android는 매번
    // 1MB에서 403 — §2.3.2.1). ios는 그다음, android/default는 사실상 1MB만
    // 받아지므로 맨 뒤의 형식적 후보다.
    //
    // `ios`는 여기서 빼 두었다. 패키지가 매니페스트를 받은 뒤 **비디오** 스트림에
    // HEAD를 날려 403이면 후보를 통째로 버리는데(itag 137/299 — 오디오와 무관),
    // 실기기에서 매번 8~10초를 쓰고 항상 그 이유로 실패했다. 같은 클라이언트를
    // `_viaInnerTube`가 그 검사 없이 다시 시도하므로 잃는 것도 없다.
    final attempts = <(String, List<YoutubeApiClient>?)>[
      ('androidVr', [withAudioLanguage(YoutubeApiClient.androidVr)]),
      ('android', [withAudioLanguage(YoutubeApiClient.android)]),
      ('default', null),
    ];
    Object? lastError;
    AudioUnavailableException? blockedReason;
    final sw = Stopwatch()..start();
    for (final (label, clients) in attempts) {
      sw.reset();
      onStage?.call('스트림 찾는 중 ($label)...');
      try {
        final manifest = await (clients == null
                ? yt.videos.streamsClient
                    .getManifest(videoId, requireWatchPage: _requireWatchPage)
                : yt.videos.streamsClient.getManifest(videoId,
                    ytClients: clients, requireWatchPage: _requireWatchPage))
            .timeout(const Duration(seconds: 30));
        debugPrint('[BT] download.t: manifest[$label]=${sw.elapsedMilliseconds}ms');
        // 매니페스트에 여러 언어 트랙이 섞여 오면 기본(원본) 트랙만 남긴다.
        final tracked = preferDefaultAudioTrack(manifest.audioOnly);
        final mp4 =
            tracked.where((s) => s.container == StreamContainer.mp4);
        // iOS AVPlayer는 webm/opus를 재생 못 하므로 저장 파일도 mp4만 받는다.
        // (mp4가 없으면 이 클라이언트는 건너뛰고 다음 후보로.)
        final Iterable<AudioOnlyStreamInfo> pool =
            Platform.isIOS ? mp4 : tracked;
        if (pool.isEmpty) {
          debugPrint('[BT] download manifest[$label]: no mp4 audio on iOS, skip');
          continue;
        }
        final audio = pool.withHighestBitrate();
        // 여기서 URL을 미리 찔러 보지 **않는다.** 예전엔 1KB만 받아 검증했는데,
        // ⑴ 그 판정이 실제 다운로드와 어긋났고(실측 2026-08-18: 검증 206 →
        // 곧이은 다운로드 403), ⑵ 요청을 한 번 더 보내는 것 자체가 이미 의심받는
        // IP의 rate limit을 더 건드리며, ⑶ 죽은 URL로 다운로드가 멈추던 원래
        // 문제는 이제 다운로더를 직접 구현해(_rangedDownload) 403이 즉시 예외로
        // 드러나므로 사라졌다. 검증은 실제 다운로드가 대신한다.
        debugPrint('[BT] download manifest[$label] ok -> '
            '${audio.container.name}/${audio.audioCodec} ${audio.bitrate} '
            '(${sw.elapsedMilliseconds}ms)');
        return audio;
      } catch (e) {
        lastError = e;
        debugPrint('[BT] download manifest[$label] failed after '
            '${sw.elapsedMilliseconds}ms: $e');
        // 차단(봇 확인/rate limit)은 **클라이언트마다 다르게** 걸린다(ios는
        // 막혀도 androidVr는 통과하는 식). 그래서 여기서 끊지 않고 사유만 기억해
        // 둔 뒤 남은 후보를 계속 시도하고, 전부 실패했을 때만 이 사유로 안내한다.
        blockedReason ??= _youtubeBlocked(e);
      }
    }
    // 후보가 전부 봇 확인/로그인 요구에 막힌 경우. 이때는 유튜브에 다시 물어도
    // 같은 답이라 진단 요청(15초)을 생략하고 바로 안내한다.
    if (blockedReason != null) {
      debugPrint('[BT] download: 모든 후보가 봇 확인/로그인 요구에 막힘');
      throw blockedReason;
    }
    // 모든 후보가 실패했으면 YouTube에 왜 재생 불가인지 직접 물어 사용자용
    // 안내로 바꾼다. 판별 불가면 기존 기술 메시지(라이브러리 고장 진단용) 유지.
    final diagnosis = await _diagnoseUnavailable(videoId);
    if (diagnosis != null) throw diagnosis;
    throw Exception('모든 매니페스트 후보 실패: $lastError');
  }

  /// InnerTube player를 **직접** 호출해 오디오 스트림을 고른다(패키지 우회).
  ///
  /// 왜 필요한가: `getManifest`는 매니페스트를 받은 뒤 `streams.first`에 HEAD를
  /// 날려 403이면 후보 전체를 버린다. 그런데 `streams.first`는 보통 **비디오**
  /// 스트림이라(실측: `returned 403 (stream: 137)` — itag 137은 1080p 비디오)
  /// 오디오는 멀쩡한데도 클라이언트가 통째로 탈락한다. 우리는 오디오만 필요하니
  /// 그 판정을 따를 이유가 없다.
  ///
  /// [muxed]면 `adaptiveFormats` 대신 `formats`(progressive)에서 **itag 18**을
  /// 고른다. itag 18은 360p H.264 + AAC를 하나로 합친 옛 포맷인데, 유튜브가
  /// PO token을 요구하는 지금도 **토큰 없이 끝까지 받아지는 유일한 포맷**이다
  /// (§2.3.2.4). 오디오만 필요한 우리에겐 비디오가 낭비지만, 받히지 않는 것보다
  /// 낫다. 컨테이너가 mp4/AAC라 iOS AVPlayer가 그대로 재생한다(§2.2).
  static Future<ResolvedAudioStream?> _viaInnerTube(
    String videoId,
    String label,
    Map<String, dynamic> client, {
    bool muxed = false,
  }) async {
    final http = HttpClient();
    try {
      final uri = Uri.parse(
          'https://www.youtube.com/youtubei/v1/player?prettyPrint=false');
      final req = await http.postUrl(uri);
      req.headers.contentType = ContentType.json;
      req.headers.set('X-YouTube-Client-Name', '${client['_num']}');
      req.headers.set('X-YouTube-Client-Version', '${client['clientVersion']}');
      final payload = Map<String, dynamic>.from(client)..remove('_num');
      req.add(utf8.encode(jsonEncode({
        'context': {'client': payload},
        'videoId': videoId,
        'contentCheckOk': true,
        'racyCheckOk': true,
      })));
      final resp = await req.close().timeout(const Duration(seconds: 20));
      if (resp.statusCode != 200) {
        debugPrint('[BT] innertube[$label]: HTTP ${resp.statusCode}');
        return null;
      }
      final json =
          jsonDecode(await resp.transform(utf8.decoder).join()) as Map<String, dynamic>;
      final status =
          (json['playabilityStatus'] as Map<String, dynamic>?)?['status'];
      final streaming = json['streamingData'] as Map<String, dynamic>?;
      // 삼항 안에서 `?[`를 쓰면 Dart 파서가 삼항의 `?`와 헷갈리므로 풀어 쓴다.
      final Object? rawFormats = streaming == null
          ? null
          : (muxed ? streaming['formats'] : streaming['adaptiveFormats']);
      final formats = (rawFormats as List<dynamic>?) ?? const [];
      // 서명이 걸린(url 없는) 포맷은 JS 솔버 없이 못 쓰므로 제외한다.
      final audio = formats
          .cast<Map<String, dynamic>>()
          .where((f) =>
              f['url'] != null &&
              (muxed
                  ? f['itag'] == 18
                  : (f['mimeType'] as String? ?? '').startsWith('audio/mp4')))
          .toList();
      if (audio.isEmpty) {
        debugPrint('[BT] innertube[$label]: $status, 평문 오디오 없음');
        return null;
      }
      // 자동 더빙 대응(§2.4): default 트랙이 있으면 그것만 남긴다.
      final defaults = audio.where((f) {
        final track = f['audioTrack'] as Map<String, dynamic>?;
        return track == null || track['audioIsDefault'] == true;
      }).toList();
      final pool = defaults.isEmpty ? audio : defaults;
      pool.sort((a, b) =>
          ((b['bitrate'] as num?) ?? 0).compareTo((a['bitrate'] as num?) ?? 0));
      final best = pool.first;
      final details = json['videoDetails'] as Map<String, dynamic>?;
      final seconds = int.tryParse('${details?['lengthSeconds']}') ?? 0;
      debugPrint('[BT] innertube[$label]: $status itag=${best['itag']} '
          'size=${best['contentLength'] ?? "(미제공)"} '
          '${muxed ? "(영상 포함 progressive)" : ""}');
      return ResolvedAudioStream(
        url: Uri.parse(best['url'] as String),
        sizeBytes: int.tryParse('${best['contentLength']}') ?? 0,
        mimeType: best['mimeType'] as String? ?? '',
        via: 'innertube-$label',
        title: details?['title'] as String?,
        author: details?['author'] as String?,
        duration: seconds > 0 ? Duration(seconds: seconds) : null,
      );
    } catch (e) {
      debugPrint('[BT] innertube[$label] 실패: $e');
      return null;
    } finally {
      http.close();
    }
  }

  /// `_viaInnerTube`에 넘길 클라이언트 컨텍스트. `_num`은 헤더용 클라이언트 번호.
  static const Map<String, dynamic> _ctxAndroidVr = {
    '_num': 28,
    'clientName': 'ANDROID_VR',
    'clientVersion': '1.62.27',
    'deviceMake': 'Oculus',
    'deviceModel': 'Quest 3',
    'androidSdkVersion': 32,
    'osName': 'Android',
    'osVersion': '12',
    'hl': kPreferredAudioLanguage,
    'gl': 'KR',
  };

  static const Map<String, dynamic> _ctxAndroid = {
    '_num': 3,
    'clientName': 'ANDROID',
    'clientVersion': '20.10.38',
    'androidSdkVersion': 30,
    'hl': kPreferredAudioLanguage,
    'gl': 'KR',
  };

  static const Map<String, dynamic> _ctxIos = {
    '_num': 5,
    'clientName': 'IOS',
    'clientVersion': '20.10.4',
    'deviceMake': 'Apple',
    'deviceModel': 'iPhone16,2',
    'osName': 'iPhone',
    'osVersion': '18.3.2.22D82',
    'hl': kPreferredAudioLanguage,
    'gl': 'KR',
  };

  /// 스트림 URL의 `dur` 파라미터(초)로 길이를 얻는다. 요청이 필요 없다.
  /// 실측(2026-08-18): `dur=322.803` ↔ 실제 323초로 일치.
  static Duration? _durationFromUrl(Uri url) {
    final dur = double.tryParse(url.queryParameters['dur'] ?? '');
    if (dur == null || dur <= 0) return null;
    return Duration(milliseconds: (dur * 1000).round());
  }

  /// [url]에서 [tmp]로 받아 받은 바이트 수를 돌려준다. 취소되면 받은 만큼만
  /// 돌려주고 끝낸다(호출부가 `.part`를 지운다). 403이면 [_StreamForbidden].
  /// [fetchChunk]가 주어지면 앱이 직접 받지 않고 그 콜백(웹뷰 안 fetch)으로 받는다.
  static Future<int> _downloadToFile(
    File tmp,
    Uri url,
    int total, {
    void Function(int received, int total)? onBytes,
    DownloadCancelToken? cancelToken,
    Future<List<int>?> Function(Uri url, int from, int to)? fetchChunk,
  }) async {
    var received = 0;
    var lastLogged = 0;
    // 재시도로 다시 들어올 수 있으므로 항상 처음부터 쓴다.
    final sink = tmp.openWrite();
    try {
      final source = fetchChunk != null
          ? _webViewDownload(url, total, fetchChunk, cancelToken: cancelToken)
          : _rangedDownload(url, total, cancelToken: cancelToken);
      // 데이터가 _stallTimeout 동안 한 조각도 안 오면 끊는다.
      final bytes = source.timeout(
        _stallTimeout,
        onTimeout: (sink) => sink.addError(
          const AudioUnavailableException(
            '다운로드가 진행되지 않아 중단했습니다.\n'
            '잠시 후 다시 시도해 주세요.',
            retryable: true,
          ),
        ),
      );
      await for (final chunk in bytes) {
        // break는 스트림 구독까지 취소하므로 남은 데이터를 더 받지 않는다.
        if (cancelToken?.isCancelled ?? false) break;
        sink.add(chunk);
        received += chunk.length;
        onBytes?.call(received, total);
        if (received - lastLogged >= 512 * 1024) {
          lastLogged = received;
          debugPrint('[BT] download progress $received/$total');
        }
      }
      await sink.flush();
    } finally {
      await sink.close();
    }
    return received;
  }

  /// 제목·채널명을 oEmbed로 가져온다(실패하면 null).
  ///
  /// watch 페이지 조회(`videos.get`)가 rate limit에 걸렸을 때의 대체 출처.
  /// oEmbed는 임베드용 공개 엔드포인트라 훨씬 가볍고 잘 막히지 않는다.
  /// 길이(duration)는 주지 않으므로 잠금화면 길이는 비게 될 수 있다.
  static Future<(String, String)?> _titleViaOembed(String videoId) async {
    final client = HttpClient();
    try {
      final uri = Uri.parse('https://www.youtube.com/oembed'
          '?url=https://www.youtube.com/watch?v=$videoId&format=json');
      final req = await client.getUrl(uri);
      final resp = await req.close().timeout(const Duration(seconds: 10));
      if (resp.statusCode != 200) {
        debugPrint('[BT] oembed status=${resp.statusCode}');
        return null;
      }
      final body = await resp.transform(utf8.decoder).join();
      final json = jsonDecode(body) as Map<String, dynamic>;
      final title = (json['title'] as String?) ?? '';
      final author = (json['author_name'] as String?) ?? '';
      debugPrint('[BT] oembed ok: "$title"');
      return (title, author);
    } catch (e) {
      debugPrint('[BT] oembed failed: $e');
      return null;
    } finally {
      client.close();
    }
  }

  /// 다운로드를 **웹뷰 안에서** 수행한다. 앱의 HTTP 요청이 URL과 무관하게 403인
  /// 기기의 마지막 수단(§2.3.3).
  ///
  /// 웹뷰(m.youtube.com)에서 googlevideo로 보내는 fetch는 CORS가 허용돼 있다 —
  /// 실측(2026-08-18): `access-control-allow-origin: https://m.youtube.com`,
  /// `allow-credentials: true`, preflight가 `Range` 헤더를 허용한다.
  /// 조각을 [_webViewChunkSize]씩 받아 base64로 넘겨받으므로(채널이 문자열만
  /// 전달한다) 앱이 직접 받는 것보다 느리고 메모리도 더 쓴다. 그래서 **앞 단계가
  /// 전부 실패했을 때만** 쓴다.
  static Stream<List<int>> _webViewDownload(
    Uri url,
    int total,
    Future<List<int>?> Function(Uri url, int from, int to) fetchChunk, {
    DownloadCancelToken? cancelToken,
  }) async* {
    var from = 0;
    while (total <= 0 || from < total) {
      if (cancelToken?.isCancelled ?? false) return;
      final wantEnd = from + _webViewChunkSize;
      final end = (total > 0 && wantEnd > total) ? total : wantEnd;
      final data = await fetchChunk(url, from, end - 1);
      if (cancelToken?.isCancelled ?? false) return;
      if (data == null || data.isEmpty) {
        throw const AudioUnavailableException(
          '웹뷰 세션으로도 스트림을 받지 못했습니다.\n'
          '웹뷰에서 해당 영상이 재생되는지 확인한 뒤 다시 시도해 주세요.',
          retryable: true,
        );
      }
      from += data.length;
      yield data;
      // 크기를 모르면 한 조각만 받고 끝낸다(끝을 알 방법이 없다).
      if (total <= 0) return;
    }
  }

  /// 스트림 URL을 range로 잘라 순차 요청해 바이트를 흘린다. **모든 저장이 이
  /// 경로로 다운로드한다**(youtube_explode의 다운로더는 쓰지 않는다).
  ///
  /// 왜 직접 받나: 패키지의 `_getStream`은 응답이 403이면 매니페스트를 다시 받아
  /// 같은 URL로 재시도하는 것을 **로그도 예외도 없이 무한 반복**한다. 실제로
  /// "다운로드 시작 대기 중"에서 영영 멈추는 버그가 두 번 났다. 직접 받으면
  /// 실패가 즉시 예외로 드러나고, 재시도 횟수도 우리가 정한다.
  ///
  /// **range를 반드시 지정한다.** 그냥 GET 하면 유튜브가 재생 속도 수준으로
  /// 스로틀링한다 — 실측(2026-08-18, 3.4MB 오디오): range 없음 102초(약
  /// 270kbit/s) vs range 지정 0.9초(약 30Mbit/s), 110배 차이. 1시간짜리면
  /// 30분씩 걸린다는 뜻이다. 지정 방식은 `c=ANDROID`면 `Range` 헤더, 그 외는
  /// `range` 쿼리로, 패키지가 쓰는 방식과 동일하게 맞춘다.
  ///
  /// 조각을 나누는 이유는 긴 영상(1시간이면 60MB 남짓)에서 연결이 한 번
  /// 끊겼을 때 처음부터 다시 받지 않기 위해서다. 중간에 끊기면 받은 지점부터
  /// 같은 조각을 다시 요청한다(최대 [_chunkRetries]회).
  static Stream<List<int>> _rangedDownload(
    Uri url,
    int total, {
    DownloadCancelToken? cancelToken,
  }) async* {
    // range를 URL 쿼리로 줄지 헤더로 줄지는 URL 종류마다 다르다. 우선 관례대로
    // 고르되(ANDROID 클라이언트 URL은 헤더), 403이 나면 **반대 방식으로 한 번 더**
    // 시도한다. 어느 쪽을 받아들이는지가 URL 발급 경로마다 달라서, 이것만으로
    // 살아나는 경우가 있기 때문이다.
    var useHeaderRange = url.queryParameters['c'] == 'ANDROID';
    var swapped = false;
    final client = HttpClient();
    try {
      var from = 0;
      var failures = 0;
      while (total <= 0 || from < total) {
        if (cancelToken?.isCancelled ?? false) return;
        final wantEnd = from + _chunkSize;
        final end = (total > 0 && wantEnd > total) ? total : wantEnd;
        // 크기를 모르면 끝을 열어 둔 채 한 번에 받는다.
        final range = total > 0 ? '$from-${end - 1}' : '$from-';
        try {
          final target = useHeaderRange
              ? url
              : url.replace(queryParameters: {
                  ...url.queryParameters,
                  'range': range,
                });
          final req = await client.getUrl(target);
          YoutubeHttpClient.defaultHeaders.forEach(req.headers.set);
          if (useHeaderRange) req.headers.set('Range', 'bytes=$range');
          final resp = await req.close().timeout(const Duration(seconds: 20));
          // 403은 재시도해 봐야 똑같다(실측: 같은 403 4연발). 곧바로 위로 올려
          // PO token이 붙은 URL로 갈아타게 한다.
          //
          // from > 0에서 나는 403은 신호가 분명하다: **PO token 없는 URL**이다.
          // 유튜브는 그런 URL에 첫 1MB만 주고 그 뒤를 막는다(§2.3.3).
          if (resp.statusCode == 403) {
            await resp.drain<void>();
            if (!swapped) {
              // range 전달 방식을 바꿔 같은 구간을 한 번만 더 시도한다.
              swapped = true;
              useHeaderRange = !useHeaderRange;
              debugPrint('[BT] download: 403 (from=$from) → range 전달 방식을 '
                  '${useHeaderRange ? "헤더" : "쿼리"}로 바꿔 재시도');
              continue;
            }
            debugPrint('[BT] download: 스트림 403 (from=$from)'
                '${from > 0 ? " ← PO token 없는 URL로 보임" : ""}');
            throw const _StreamForbidden();
          }
          // 성공했으면 방식 전환 기회를 다시 살려 둔다(다음 조각에서도 쓸 수 있게).
          swapped = false;
          if (resp.statusCode >= 400) {
            throw AudioUnavailableException(
              '스트림을 받지 못했습니다 (HTTP ${resp.statusCode}).\n'
              '잠시 후 다시 시도해 주세요.',
              retryable: true,
            );
          }
          await for (final chunk in resp.timeout(_stallTimeout)) {
            from += chunk.length;
            yield chunk;
          }
          failures = 0;
          // 크기를 모르면 한 번에 다 받은 것으로 본다(재개 기준이 없다).
          if (total <= 0) return;
        } catch (e) {
          if (cancelToken?.isCancelled ?? false) return;
          // 403은 재시도 대상이 아니다 — 호출부가 다른 URL로 갈아탄다.
          if (e is _StreamForbidden) rethrow;
          failures++;
          debugPrint('[BT] download chunk 실패(#$failures, from=$from): $e');
          if (failures > _chunkRetries) rethrow;
          await Future<void>.delayed(Duration(seconds: failures));
        }
      }
    } finally {
      client.close();
    }
  }

  /// 실패가 "유튜브가 이 앱의 요청을 막은 것"인지 판별한다. 맞으면 사용자용
  /// 안내 예외(그리고 웹뷰 세션 우회의 방아쇠), 아니면 null.
  ///
  /// 두 가지를 같은 부류로 본다 — 원인도 해법도 같기 때문이다:
  /// - 봇 확인("로그인하여 봇이 아님을 확인하세요")
  /// - rate limit(`RequestLimitExceededException`, 429/sorry 페이지)
  ///
  /// 둘 다 IP·세션 평판에 걸리는 것이라 클라이언트를 바꿔도 뚫리지 않고,
  /// 웹뷰 세션(이미 정상 통과한 세션)으로 우회하는 것이 유일한 앱 내 해법이다.
  /// 문구는 요청 언어로 오는데 저장 경로는 `hl=ko`(§2.4)라 한국어가, 마지막
  /// `default` 후보는 영어가 오므로 양쪽 키워드를 모두 본다.
  static AudioUnavailableException? _youtubeBlocked(Object error) {
    final t = error.toString().toLowerCase();
    final botOrLogin = t.contains('봇이 아님') ||
        t.contains('로그인') ||
        t.contains('not a bot') ||
        t.contains('sign in') ||
        t.contains('login_required') ||
        t.contains('login required');
    final rateLimited = t.contains('requestlimitexceeded') ||
        t.contains('rate limiting') ||
        t.contains('too many requests');
    if (!botOrLogin && !rateLimited) return null;
    return AudioUnavailableException(
      rateLimited
          ? '유튜브가 이 기기의 요청을 일시적으로 제한했습니다.\n'
              '잠시 후 다시 시도해 주세요.'
          : '유튜브가 로그인(봇 확인)을 요구해 지금은 저장할 수 없습니다.\n'
              '잠시 후 다시 시도해 주세요.',
      retryable: true,
      botBlocked: true,
    );
  }

  /// 매니페스트가 모두 실패했을 때, YouTube의 재생 가능 상태를 직접 조회해
  /// 사용자용 안내 메시지를 만든다. 판별할 수 없으면 null.
  ///
  /// youtube_explode의 매니페스트 예외는 ios 경로가 널 크래시라 사유를 구분할
  /// 수 없어, InnerTube player를 가볍게 직접 호출한다(스트림 다운로드가 아니라
  /// playabilityStatus만 읽는다). 라이브 종료 직후 "처리 중"(post-live DVR)
  /// 상태에서는 어떤 스트림도 아직 발행되지 않아 이 경로로만 구분 가능하다.
  static Future<AudioUnavailableException?> _diagnoseUnavailable(
    String videoId,
  ) async {
    final client = HttpClient();
    try {
      final uri = Uri.parse(
        'https://www.youtube.com/youtubei/v1/player'
        '?key=AIzaSyB-63vPrdThhKuerbB2N_l7Kwwcxj6yUAc&prettyPrint=false',
      );
      final req = await client.postUrl(uri);
      req.headers.contentType = ContentType.json;
      // hl=en으로 받아 reason 키워드 매칭을 안정화한다(표시는 우리 문구 사용).
      req.add(utf8.encode(jsonEncode({
        'context': {
          'client': {
            'clientName': 'IOS',
            'clientVersion': '20.10.4',
            'deviceMake': 'Apple',
            'deviceModel': 'iPhone16,2',
            'userAgent': 'com.google.ios.youtube/20.10.4 '
                '(iPhone16,2; U; CPU iOS 18_3_2 like Mac OS X;)',
            'hl': 'en',
            'platform': 'MOBILE',
            'osName': 'IOS',
            'osVersion': '18.1.0.22B83',
            'timeZone': 'UTC',
            'gl': 'US',
            'utcOffsetMinutes': 0,
          },
        },
        'videoId': videoId,
      })));
      final resp = await req.close().timeout(const Duration(seconds: 15));
      if (resp.statusCode != 200) return null;
      final body = await resp.transform(utf8.decoder).join();
      final json = jsonDecode(body) as Map<String, dynamic>;
      final playability = json['playabilityStatus'] as Map<String, dynamic>?;
      final status = playability?['status'] as String?;
      final reason = (playability?['reason'] as String?) ?? '';
      final details = json['videoDetails'] as Map<String, dynamic>?;
      final isPostLiveDvr = details?['isPostLiveDvr'] == true;
      debugPrint('[BT] diagnose status=$status reason="$reason" '
          'postLiveDvr=$isPostLiveDvr');

      final lower = reason.toLowerCase();

      // 라이브 방송 관련(종료 직후 VOD 미준비/처리 중/시작 전)은 status가 OK로
      // 바뀌어도 isPostLiveDvr=true인 동안 받을 수 있는 오디오 스트림이 없다.
      // 그래서 status==OK 조기반환보다 먼저 검사한다.
      if (isPostLiveDvr ||
          lower.contains('processing') ||
          lower.contains('live event has ended') ||
          lower.contains('live event will begin') ||
          lower.contains('premiere')) {
        return const AudioUnavailableException(
          '라이브 방송이 종료되어 유튜브가 다시보기(VOD)를 준비 중입니다.\n'
          '변환이 끝나면 저장할 수 있어요. 잠시 후 다시 시도해 주세요.',
          retryable: true,
        );
      }
      if (lower.contains('bot')) {
        return const AudioUnavailableException(
          '유튜브가 봇 확인을 요구해 지금은 스트림을 가져올 수 없습니다.\n'
          '잠시 후 다시 시도해 주세요.',
          retryable: true,
        );
      }
      if (status == 'LOGIN_REQUIRED') {
        return const AudioUnavailableException(
          '로그인이 필요한 영상이라 저장할 수 없습니다(연령 제한 또는 비공개).',
        );
      }
      // status가 OK인데 여기까지 왔다면 라이브도 아니고 일시적/알 수 없는 문제 →
      // 기존 기술 메시지로 넘겨 진짜 라이브러리 고장이 드러나게 둔다(yt_probe).
      if (status == null || status == 'OK') return null;

      // UNPLAYABLE / ERROR 등: 비공개·삭제·멤버십 전용·지역 차단 등.
      return const AudioUnavailableException(
        '재생할 수 없는 영상이라 저장할 수 없습니다\n'
        '(비공개·삭제·멤버십 전용 또는 지역 차단).',
      );
    } catch (e) {
      debugPrint('[BT] diagnose failed: $e');
      return null;
    } finally {
      client.close();
    }
  }

  /// 지정 폴더(null=루트)의 저장된 오디오 목록. 제목 오름차순.
  static Future<List<SavedAudio>> list({String? folder}) async {
    final dir = await _folderDir(folder);
    final entries = await dir
        .list()
        .where((e) => e is File && e.path.endsWith('.m4a'))
        .toList();

    final result = <SavedAudio>[];
    for (final entry in entries) {
      final name = entry.uri.pathSegments.last;
      final videoId = name.substring(0, name.length - '.m4a'.length);

      var title = videoId;
      var author = '';
      Duration? duration;
      String? thumbUrl;
      final metaFile = File('${dir.path}/$videoId.json');
      if (await metaFile.exists()) {
        try {
          final m = jsonDecode(await metaFile.readAsString())
              as Map<String, dynamic>;
          title = (m['title'] as String?) ?? videoId;
          author = (m['author'] as String?) ?? '';
          final ms = m['durationMs'];
          if (ms is int) duration = Duration(milliseconds: ms);
          thumbUrl = m['thumbUrl'] as String?;
        } catch (_) {
          // 메타가 깨졌으면 파일명(videoId)만 사용.
        }
      }

      // 경로는 앱 컨테이너 UUID가 재설치마다 바뀌므로 사이드카에 저장하지 않고
      // 매번 현재 디렉터리 기준으로 재구성한다.
      final thumbFile = File('${dir.path}/$videoId.jpg');
      final thumbPath = await thumbFile.exists() ? thumbFile.path : null;

      result.add(SavedAudio(
        videoId: videoId,
        title: title,
        author: author,
        duration: duration,
        filePath: entry.path,
        thumbPath: thumbPath,
        thumbUrl: thumbUrl,
      ));
    }

    result.sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
    return result;
  }

  static Future<void> delete(String videoId, {String? folder}) async {
    final dir = await _folderDir(folder);
    for (final ext in ['.m4a', '.json', '.jpg']) {
      final f = File('${dir.path}/$videoId$ext');
      if (await f.exists()) {
        await f.delete();
      }
    }
  }
}
