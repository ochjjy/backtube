import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';

/// just_audio_background는 앱 전체에서 단일 AudioPlayer 인스턴스를 전제로 한다.
/// dispose 후 재생성하면 iOS 오디오 세션과 알림(제어센터) 바인딩이 끊기므로,
/// 유튜브 백그라운드 오디오(WebViewPage)와 저장파일 재생(SavedAudioPage)이
/// 이 하나의 인스턴스를 공유한다. 앱 생명주기 내내 살아 있어야 하므로
/// 어느 화면에서도 dispose 하지 않는다.
///
/// 주의: 이 전역은 첫 참조 시점에 생성된다. just_audio_background.init()이
/// 먼저 끝나 있어야 하므로, 플레이어를 쓰기 전에 반드시 ensureAudioReady()를
/// await 해야 한다(메뉴에서 재생 화면으로 넘어가기 직전).
final AudioPlayer btPlayer = AudioPlayer(
  audioLoadConfiguration: const AudioLoadConfiguration(
    androidLoadControl: AndroidLoadControl(
      minBufferDuration: Duration(seconds: 60),
      maxBufferDuration: Duration(minutes: 3),
      bufferForPlaybackDuration: Duration(milliseconds: 500),
      bufferForPlaybackAfterRebufferDuration: Duration(seconds: 3),
    ),
    darwinLoadControl: DarwinLoadControl(
      preferredForwardBufferDuration: Duration(seconds: 60),
    ),
  ),
);

/// 오디오 백그라운드 서비스/세션 초기화. 앱 시작 시 백그라운드로 시작하고
/// (첫 프레임을 막지 않음), 플레이어를 실제로 만들기 전에 await로 완료를 보장한다.
/// 한 번만 실행되도록 Future를 캐시한다.
Future<void>? _audioInitFuture;

Future<void> ensureAudioReady() => _audioInitFuture ??= _initAudio();

Future<void> _initAudio() async {
  debugPrint('[BT] boot: _initAudio start');
  final sw = Stopwatch()..start();
  await JustAudioBackground.init(
    androidNotificationChannelId: 'com.example.backtube.channel.audio',
    androidNotificationChannelName: 'BackTube Audio Playback',
    androidNotificationOngoing: true,
  );
  debugPrint('[BT] boot: JustAudioBackground.init done ${sw.elapsedMilliseconds}ms');
  final session = await AudioSession.instance;
  debugPrint('[BT] boot: AudioSession.instance ${sw.elapsedMilliseconds}ms');
  await session.configure(const AudioSessionConfiguration.music());
  debugPrint('[BT] boot: audio init total ${sw.elapsedMilliseconds}ms');
}
