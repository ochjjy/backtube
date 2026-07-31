// 오디오 트랙(언어) 진단용. 자동 더빙(auto-dubbing) 영상에서 hl(en/ko)에 따라
// 어느 트랙이 default(*)로 오는지, 앱의 실제 선택이 무엇인지 확인한다.
// "한국어 영상이 영어로 저장/재생된다"류 신고가 오면 이 스크립트로 재현한다.
//
// 사용(주의: --define 은 반드시 파일 경로 '앞'에 와야 한다):
//   dart run --define=VID=<videoId> tool/yt_track_probe.dart
// ignore_for_file: avoid_print
import 'package:backtube/yt_audio_language.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

String desc(AudioOnlyStreamInfo s) {
  final t = s.audioTrack;
  final mark = (t?.audioIsDefault ?? false) ? '*' : '';
  return '${s.container.name}/${s.audioCodec} '
      '${s.bitrate.kiloBitsPerSecond.round()}k '
      'track=${t == null ? "<none>" : "${t.id}$mark \"${t.displayName}\""}';
}

Future<void> dumpAll(
    YoutubeExplode yt, String videoId, YoutubeApiClient client) async {
  final manifest =
      await yt.videos.streamsClient.getManifest(videoId, ytClients: [client]);
  for (final s in manifest.audioOnly) {
    print('    ${desc(s)}');
  }
}

Future<void> main() async {
  final videoId = const String.fromEnvironment('VID');
  if (videoId.isEmpty) {
    print('사용법: dart run --define=VID=<videoId> tool/yt_track_probe.dart');
    return;
  }
  final yt = YoutubeExplode();
  try {
    final video = await yt.videos.get(videoId);
    print('title: ${video.title}\n');

    // 내장 클라이언트(hl=en) — 자동 더빙 영상이면 영어 트랙이 default로 온다.
    print('=== ios (내장, hl=en) 전체 트랙 ===');
    await dumpAll(yt, videoId, YoutubeApiClient.ios);

    // 앱이 실제로 쓰는 클라이언트(hl=ko) — 한국어(원본) 트랙이 default로 와야 한다.
    print('\n=== ios (withAudioLanguage, hl=$kPreferredAudioLanguage) 전체 트랙 ===');
    await dumpAll(yt, videoId, withAudioLanguage(YoutubeApiClient.ios));

    // 앱의 최종 선택(저장/재생에 실제 쓰이는 스트림).
    final manifest = await yt.videos.streamsClient
        .getManifest(videoId, ytClients: [withAudioLanguage(YoutubeApiClient.ios)]);
    final mp4 = preferDefaultAudioTrack(manifest.audioOnly)
        .where((s) => s.container == StreamContainer.mp4);
    print('\n>>> 앱 최종 선택: ${desc(mp4.withHighestBitrate())}');
  } catch (e, st) {
    print('FAIL: $e\n$st');
  } finally {
    yt.close();
  }
}
