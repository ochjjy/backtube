import 'dart:async';

import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';

/// just_audio_background는 앱 전체에서 단일 AudioPlayer 인스턴스를 전제로 한다.
/// dispose 후 재생성하면 iOS 오디오 세션과 알림(제어센터) 바인딩이 끊기므로,
/// 저장파일 재생(SavedAudioPage/PlayerScreen)이 이 하나의 인스턴스를 쓴다.
/// 앱 생명주기 내내 살아 있어야 하므로 어느 화면에서도 dispose 하지 않는다.
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
      // 라이브(HLS) 데이터 절약용 상한. 평소에는 라이브 최저 변형(실측 약
      // 228kbps)을 직접 지정하므로 걸리지 않지만, 변형 선택이 실패해 master
      // 매니페스트로 폴백하면 AVPlayer가 1080p(4.5Mbps)를 골라 버린다.
      // 그 최악의 경우를 막는 안전장치다. 저장 파일(로컬 재생)에는 영향 없다.
      preferredPeakBitRate: 320000,
      // 정지 중에는 라이브를 따라가느라 계속 내려받지 않는다(기본값이지만 명시).
      canUseNetworkResourcesForLiveStreamingWhilePaused: false,
    ),
  ),
);

/// btPlayer에 지금 로드돼 있는 오디오의 출처.
/// SavedAudioPage는 origin == saved 일 때만 현재 곡을 물려받고, LiveSession은
/// origin != live가 되면(=다른 재생이 시작되면) 스스로 물러난다.
/// (web은 유튜브 웹뷰의 백그라운드 자동 재생 시절의 값으로, 그 경로를 제거한
/// 지금은 세팅되지 않는다. 웹 소스를 다시 로드하는 코드가 생기면 그때 사용할 것.)
enum BtPlaybackOrigin { none, web, saved, live }

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

/// 인터럽션(문자·전화·다른 앱 소리)이 끝난 뒤 재생을 되살려야 하는지.
/// 사용자가 직접 누른 일시정지와 구분해야 하므로 [btPlayIntent]와 별개로 둔다 —
/// 인터럽트로 인한 정지는 "사용자의 의도"가 아니다(§2.1).
bool _resumeAfterInterruption = false;

/// iOS 오디오 세션 인터럽션 처리.
///
/// **이게 없으면 문자 한 통에 재생이 영영 멈춘다.** 알림음·전화가 오면 iOS가
/// 세션을 끊는데(`begin`), 앱이 아무것도 하지 않으면 인터럽트가 끝나도
/// (`end`) 세션이 되살아나지 않아 그대로 무음이 된다. 실제로 그 버그가 났다.
///
/// 처리 규칙(just_audio·audio_session이 권장하는 형태):
/// - `duck`: iOS가 알아서 볼륨만 줄인다 → 건드리지 않는다.
/// - `pause`/`unknown` 시작: 재생 중이었으면 멈추고 "되살릴 대상"으로 표시.
/// - `pause` 종료: 사용자의 의도가 여전히 재생이면 세션을 다시 활성화하고 재생.
/// - `unknown` 종료: 자동 재개하지 않는다. 다른 앱이 오디오를 가져간 경우라
///   되살리면 남의 재생을 끊는다.
void _attachInterruptionHandling(AudioSession session) {
  session.interruptionEventStream.listen((event) async {
    if (event.begin) {
      switch (event.type) {
        case AudioInterruptionType.duck:
          break;
        case AudioInterruptionType.pause:
        case AudioInterruptionType.unknown:
          if (btPlayer.playing) {
            // btPlayIntent는 건드리지 않는다. 사용자가 정지한 게 아니다.
            _resumeAfterInterruption = true;
            debugPrint('[BT] audio: 인터럽션 시작(${event.type}) → 일시정지');
            await btPlayer.pause();
          }
          break;
      }
      return;
    }
    switch (event.type) {
      case AudioInterruptionType.duck:
        break;
      case AudioInterruptionType.pause:
        if (_resumeAfterInterruption && btPlayIntent) {
          debugPrint('[BT] audio: 인터럽션 종료 → 세션 재활성화 후 재생 재개');
          // 인터럽트 뒤에는 세션이 비활성 상태다. 살리지 않고 play()만 하면
          // iOS에서 -11800/-11819로 실패한다(§2.5).
          try {
            await session.setActive(true);
          } catch (e) {
            debugPrint('[BT] audio: 세션 재활성화 실패 $e');
          }
          // play()는 재생이 끝날 때 완료되는 Future다 → await 금지(§2.4.1).
          unawaited(btPlayer.play());
        }
        break;
      case AudioInterruptionType.unknown:
        // 다른 앱이 오디오를 가져간 경우. 자동 재개하면 남의 재생을 끊는다.
        debugPrint('[BT] audio: 인터럽션 종료(unknown) → 자동 재개하지 않음');
        break;
    }
    _resumeAfterInterruption = false;
  });
}

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
  _attachInterruptionHandling(session);
  audioReady = true;
  debugPrint('[BT] boot: audio init done total=${sw.elapsedMilliseconds}ms '
      '(JustAudioBackground.init=${tInit}ms, '
      'AudioSession.instance=${tSession - tInit}ms, '
      'configure=${sw.elapsedMilliseconds - tSession}ms)');
}
