import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

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
  static Future<SavedAudio> saveAudio(
    String videoId, {
    void Function(int received, int total)? onBytes,
  }) async {
    final yt = YoutubeExplode();
    try {
      debugPrint('[BT] download start videoId=$videoId');
      final video =
          await yt.videos.get(videoId).timeout(const Duration(seconds: 30));
      debugPrint('[BT] download video ok: "${video.title}" '
          'videoDuration=${video.duration}');

      final audio = await _resolveAudioStream(yt, videoId);
      final total = audio.size.totalBytes;
      // 참고: 명목 비트레이트로 계산한 예상 길이. 실제 스트림 길이와 비교용.
      final approxSeconds = audio.bitrate.bitsPerSecond > 0
          ? (total * 8 / audio.bitrate.bitsPerSecond).round()
          : 0;
      debugPrint('[BT] download stream ${audio.container.name}/'
          '${audio.audioCodec} ${audio.bitrate} size=$total bytes '
          '(~${approxSeconds ~/ 60}:${(approxSeconds % 60).toString().padLeft(2, '0')} '
          'at nominal bitrate)');

      final file = await _audioFile(videoId);
      // 다운로드 중 앱이 죽어도 반쪽짜리 파일이 목록에 뜨지 않게 .part로 받고
      // 완료 후 원자적으로 rename 한다.
      final tmp = File('${file.path}.part');

      var received = 0;
      var lastLogged = 0;
      final sink = tmp.openWrite();
      try {
        await for (final chunk in yt.videos.streamsClient.get(audio)) {
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
      debugPrint('[BT] download finished received=$received bytes');

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

      final thumbUrl = video.thumbnails.highResUrl;
      final thumbPath = await _downloadThumbnail(videoId, thumbUrl);

      final meta = SavedAudio(
        videoId: videoId,
        title: video.title,
        author: video.author,
        duration: video.duration,
        filePath: file.path,
        thumbPath: thumbPath,
        thumbUrl: thumbUrl,
      );
      await (await _metaFile(videoId)).writeAsString(jsonEncode({
        'videoId': videoId,
        'title': video.title,
        'author': video.author,
        'durationMs': video.duration?.inMilliseconds,
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
  /// androidVr·default 순으로 폴백한다. (재생 로더 _loadPlayableAudio와 동일 순서)
  static Future<AudioOnlyStreamInfo> _resolveAudioStream(
    YoutubeExplode yt,
    String videoId,
  ) async {
    final attempts = <(String, List<YoutubeApiClient>?)>[
      ('ios', [YoutubeApiClient.ios]),
      ('androidVr', [YoutubeApiClient.androidVr]),
      ('default', null),
    ];
    Object? lastError;
    for (final (label, clients) in attempts) {
      try {
        final manifest = await (clients == null
                ? yt.videos.streamsClient.getManifest(videoId)
                : yt.videos.streamsClient
                    .getManifest(videoId, ytClients: clients))
            .timeout(const Duration(seconds: 30));
        final mp4 = manifest.audioOnly
            .where((s) => s.container == StreamContainer.mp4);
        // iOS AVPlayer는 webm/opus를 재생 못 하므로 저장 파일도 mp4만 받는다.
        // (mp4가 없으면 이 클라이언트는 건너뛰고 다음 후보로.)
        final Iterable<AudioOnlyStreamInfo> pool =
            Platform.isIOS ? mp4 : manifest.audioOnly;
        if (pool.isEmpty) {
          debugPrint('[BT] download manifest[$label]: no mp4 audio on iOS, skip');
          continue;
        }
        final audio = pool.withHighestBitrate();
        debugPrint('[BT] download manifest[$label] ok -> '
            '${audio.container.name}/${audio.audioCodec} ${audio.bitrate}');
        return audio;
      } catch (e) {
        lastError = e;
        debugPrint('[BT] download manifest[$label] failed: $e');
      }
    }
    throw Exception('모든 매니페스트 후보 실패: $lastError');
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
