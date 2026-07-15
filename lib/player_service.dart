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

/// btPlayer에 지금 로드돼 있는 오디오의 출처.
/// 유튜브 웹(WebViewPage)이 백그라운드 재생용으로 미리 로드(prepare)해 둔
/// 소스를, 저장파일 화면(SavedAudioPage)이 "이 저장곡을 재생 중"이라고
/// 오인하지 않도록 출처를 표시한다. 두 화면이 같은 videoId를 가리킬 때
/// (= 보고 있던 영상을 그대로 저장한 경우) 재생이 엉키는 것을 막는다.
enum BtPlaybackOrigin { none, web, saved }

BtPlaybackOrigin btPlaybackOrigin = BtPlaybackOrigin.none;

/// 사용자가 마지막으로 요청한 재생 의도(재생=true / 일시정지=false).
/// 저장파일 자동 시작 직후의 재생 재시도(_playWithRetry)가, 그 사이 사용자가
/// 누른 일시정지를 "재생 실패"로 오인해 다시 재생해 버리는 것을 막는다.
bool btPlayIntent = false;

/// 오디오 백그라운드 서비스/세션 초기화. 앱 시작 시 백그라운드로 시작하고
/// (첫 프레임을 막지 않음), 플레이어를 실제로 만들기 전에 await로 완료를 보장한다.
/// 한 번만 실행되도록 Future를 캐시한다.
Future<void>? _audioInitFuture;

/// 오디오 초기화가 끝났는지. 메뉴에서 재생 화면 진입 시, 아직이면 진행 표시를
/// 띄우기 위해 참조한다(초기화는 기기에 따라 수 초 걸릴 수 있음).
bool audioReady = false;

Future<void> ensureAudioReady() => _audioInitFuture ??= _initAudio();

Future<void> _initAudio() async {
  debugPrint('[BT] boot: _initAudio start');
  final sw = Stopwatch()..start();
  await JustAudioBackground.init(
    androidNotificationChannelId: 'com.example.backtube.channel.audio',
    androidNotificationChannelName: 'BackTube Audio Playback',
    androidNotificationOngoing: true,
  );
  final tInit = sw.elapsedMilliseconds;
  final session = await AudioSession.instance;
  final tSession = sw.elapsedMilliseconds;
  await session.configure(const AudioSessionConfiguration.music());
  audioReady = true;
  debugPrint('[BT] boot: audio init done total=${sw.elapsedMilliseconds}ms '
      '(JustAudioBackground.init=${tInit}ms, '
      'AudioSession.instance=${tSession - tInit}ms, '
      'configure=${sw.elapsedMilliseconds - tSession}ms)');
}
