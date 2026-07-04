import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:just_audio/just_audio.dart';
import 'package:audio_session/audio_session.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';
import 'package:just_audio_background/just_audio_background.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await JustAudioBackground.init(
    androidNotificationChannelId: 'com.example.backtube.channel.audio',
    androidNotificationChannelName: 'BackTube Audio Playback',
    androidNotificationOngoing: true,
  );
  final session = await AudioSession.instance;
  await session.configure(const AudioSessionConfiguration.music());
  runApp(const MaterialApp(home: WebViewPage()));
}

class WebViewPage extends StatefulWidget {
  const WebViewPage({super.key});

  @override
  State<WebViewPage> createState() => _WebViewPageState();
}

class _WebViewPageState extends State<WebViewPage> with WidgetsBindingObserver {
  late final AudioPlayer _player;
  bool _audioLoading = false;
  bool _audioPlaying = false;
  bool _backgroundAudioLoading = false;
  bool _backgroundAudioPrepared = false;
  bool _isInBackground = false;
  bool _playWhenPrepared = false;
  bool _lastKnownWebVideoWasPlaying = false;
  Duration _lastKnownWebPosition = Duration.zero;
  Timer? _foregroundPrepareTimer;
  Timer? _manifestRefreshTimer;
  StreamSubscription<PlayerState>? _playerStateSubscription;
  StreamSubscription<PlaybackEvent>? _playbackEventSubscription;
  StreamSubscription<AudioInterruptionEvent>? _interruptionSubscription;
  StreamSubscription<void>? _becomingNoisySubscription;
  bool _resumeAfterInterruption = false;
  String? _lastKnownWebVideoId;
  String? _backgroundVideoId;
  MediaItem? _backgroundMediaItem;
  late final WebViewController _controller;
  static const String _jsChannelName = 'FullscreenListener';
  static const MethodChannel _lifecycleChannel =
      MethodChannel('backtube/lifecycle');

  bool _iosBackgroundGraceActive = false;

  /// iOS는 오디오가 아직 재생 전이면 백그라운드 진입 직후 앱을 suspend한다.
  /// beginBackgroundTask로 ~30초 유예를 받아 스트림 로딩과 재생 시작을
  /// 끝낼 시간을 확보한다. 재생이 시작되면 audio 백그라운드 모드가 이어받는다.
  Future<void> _beginIosBackgroundGrace() async {
    if (!Platform.isIOS) return;
    _iosBackgroundGraceActive = true;
    try {
      await _lifecycleChannel.invokeMethod<void>('beginBackgroundTask');
    } catch (e) {
      _btLog('beginBackgroundTask error: $e');
    }
  }

  Future<void> _endIosBackgroundGrace() async {
    if (!Platform.isIOS || !_iosBackgroundGraceActive) return;
    _iosBackgroundGraceActive = false;
    try {
      await _lifecycleChannel.invokeMethod<void>('endBackgroundTask');
    } catch (e) {
      _btLog('endBackgroundTask error: $e');
    }
  }

  int? _swipePointerId;
  Offset? _swipeStart;
  DateTime? _swipeStartTime;
  bool _swipeNavInProgress = false;

  Future<void> _kickWebViewRender() async {
    try {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await _controller.runJavaScript(r"""
(function() {
  try {
    // paint 갱신 유도 (스크롤 위치는 원복)
    window.scrollBy(0, 1);
    window.scrollBy(0, -1);
    window.dispatchEvent(new Event('scroll'));
    window.dispatchEvent(new Event('resize'));
  } catch (e) {}
})();
""");
    } catch (_) {
      // ignore
    }
  }

  Future<void> _goBackWithRepaint() async {
    if (await _controller.canGoBack()) {
      await _controller.goBack();
      await _kickWebViewRender();
    }
  }

  Future<void> _goForwardWithRepaint() async {
    if (await _controller.canGoForward()) {
      await _controller.goForward();
      await _kickWebViewRender();
    }
  }

  void _onPointerDown(PointerDownEvent e) {
    // 멀티터치/중복 포인터는 무시
    if (_swipePointerId != null) return;
    _swipePointerId = e.pointer;
    _swipeStart = e.position;
    _swipeStartTime = DateTime.now();
  }

  void _onPointerUp(PointerUpEvent e) {
    if (_swipePointerId != e.pointer) return;

    final start = _swipeStart;
    final startTime = _swipeStartTime;
    _swipePointerId = null;
    _swipeStart = null;
    _swipeStartTime = null;

    if (start == null || startTime == null) return;

    final dtMs = DateTime.now().difference(startTime).inMilliseconds;
    if (dtMs <= 0 || dtMs > 600) return;

    final dx = e.position.dx - start.dx;
    final dy = e.position.dy - start.dy;

    // 수평 스와이프만(세로 스크롤은 통과)
    if (dx.abs() < 80) return;
    if (dx.abs() < (dy.abs() * 1.5)) return;

    if (_swipeNavInProgress) return;
    _swipeNavInProgress = true;

    Future<void>(() async {
      try {
        if (dx > 0) {
          // 좌→우: 이전
          await _goBackWithRepaint();
        } else {
          // 우→좌: 앞으로
          await _goForwardWithRepaint();
        }
      } finally {
        _swipeNavInProgress = false;
      }
    });
  }

  @override
  void initState() {
    super.initState();
    // just_audio_background는 단일 플레이어 인스턴스를 전제로 하므로
    // 앱 생명주기 동안 하나만 만들어 재사용한다. 버퍼를 넉넉히 잡아
    // 백그라운드 네트워크 흔들림에도 재생이 끊기지 않게 한다.
    _player = AudioPlayer(
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
    _attachPlayerDebugLogs(_player);
    _setupAudioSessionHandlers();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..addJavaScriptChannel(_jsChannelName, onMessageReceived: (msg) async {
        // 포그라운드에서 웹 영상이 다시 재생되면 오디오를 넘겨준다(이중 재생 방지).
        if ((msg.message == 'video_play' || msg.message == 'video_playing') &&
            !_isInBackground &&
            _player.playing) {
          await _player.pause();
          if (mounted) {
            setState(() {
              _audioPlaying = false;
            });
          }
        }
        await _prepareBackgroundAudioWhileForeground();
      })
      ..setNavigationDelegate(NavigationDelegate(
        onPageFinished: (url) async {
          // 유튜브 전체화면 버튼 및 <video> 클릭 감지용 JS 삽입
          await _controller.runJavaScript('''
            (function() {
              function addFSListener() {
                var btn = document.querySelector('.ytp-fullscreen-button');
                if (btn && !btn._fsListenerAdded) {
                  btn._fsListenerAdded = true;
                  btn.addEventListener('click', function() {
                    FullscreenListener.postMessage('fullscreen');
                  });
                }
              }
              function addVideoListener() {
                var v = document.querySelector('video');
                if (v && !v._touchListenerAdded) {
                  v._touchListenerAdded = true;
                  v.addEventListener('click', function() {
                    FullscreenListener.postMessage('video_tap');
                  });
                  v.addEventListener('play', function() {
                    FullscreenListener.postMessage('video_play');
                  });
                  v.addEventListener('playing', function() {
                    FullscreenListener.postMessage('video_playing');
                  });
                }
              }
              setInterval(function() { addFSListener(); addVideoListener(); }, 1000);
            })();
          ''');
          await _injectPlaybackStateTracker();
        },
      ))
      ..loadRequest(Uri.parse('https://m.youtube.com'));
    WidgetsBinding.instance.addObserver(this);
    _foregroundPrepareTimer = Timer.periodic(
      const Duration(seconds: 3),
      (_) => _prepareBackgroundAudioWhileForeground(),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _foregroundPrepareTimer?.cancel();
    _manifestRefreshTimer?.cancel();
    _playerStateSubscription?.cancel();
    _playbackEventSubscription?.cancel();
    _interruptionSubscription?.cancel();
    _becomingNoisySubscription?.cancel();
    _player.dispose();
    super.dispose();
  }

  Future<void> _activateAudioSession() async {
    try {
      final session = await AudioSession.instance;
      await session.setActive(true);
    } catch (e) {
      _btLog('audio session activate error: $e');
    }
  }

  /// iOS에서 전화·Siri·타 앱 오디오로 세션이 끊겼다가 돌아올 때,
  /// 그리고 이어폰이 뽑혔을 때의 동작을 처리한다.
  Future<void> _setupAudioSessionHandlers() async {
    final session = await AudioSession.instance;

    _interruptionSubscription =
        session.interruptionEventStream.listen((event) async {
      _btLog(
          'audio interruption begin=${event.begin} type=${event.type}');
      if (event.begin) {
        if (event.type != AudioInterruptionType.duck) {
          _resumeAfterInterruption = _player.playing;
          await _player.pause();
        }
      } else {
        if (event.type == AudioInterruptionType.pause &&
            _resumeAfterInterruption) {
          _resumeAfterInterruption = false;
          await _activateAudioSession();
          await _player.play();
        }
      }
    });

    // 이어폰/블루투스가 분리되면 스피커로 크게 흘러나오지 않게 일시정지.
    _becomingNoisySubscription =
        session.becomingNoisyEventStream.listen((_) async {
      _btLog('becoming noisy: pausing');
      _resumeAfterInterruption = false;
      await _player.pause();
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _btLog('lifecycle=$state');
    if (state == AppLifecycleState.inactive) {
      _isInBackground = true;
      _beginIosBackgroundGrace();
      _startBackgroundAudioIfNeeded(allowWebViewProbe: true);
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      _isInBackground = true;
      _startBackgroundAudioIfNeeded();
    } else if (state == AppLifecycleState.resumed) {
      _isInBackground = false;
      // 백그라운드에서 예약해 둔 자동 재생이 포그라운드 복귀 후 뒤늦게
      // 발동해 웹 영상과 겹치지 않게 취소한다.
      _playWhenPrepared = false;
      _endIosBackgroundGrace();
      _syncOnResume();
    }
  }

  /// 포그라운드 복귀 시 웹 영상과 백그라운드 오디오가 동시에 울리지 않게 정리한다.
  /// - 웹 영상이 이미 재생 중(알림창만 내렸다 올린 경우 등)이면 오디오를 멈춘다.
  /// - 웹 영상이 멈춰 있으면 오디오를 계속 틀고, 영상 위치만 오디오에 맞춰 둔다.
  Future<void> _syncOnResume() async {
    try {
      final videoPlaying = await _isWebVideoCurrentlyPlaying();
      if (videoPlaying) {
        if (_player.playing) {
          await _player.pause();
          if (mounted) {
            setState(() {
              _audioPlaying = false;
            });
          }
        }
      } else if (_player.playing) {
        final seconds = _player.position.inMilliseconds / 1000.0;
        await _controller.runJavaScript('''
          (function() {
            var v = document.querySelector('video');
            if (v) { try { v.currentTime = $seconds; } catch (e) {} }
          })();
        ''');
      }
    } catch (e) {
      _btLog('syncOnResume error: $e');
    }
  }

  Future<bool> _isWebVideoCurrentlyPlaying() async {
    final result = await _controller.runJavaScriptReturningResult('''
      (function() {
        var v = document.querySelector('video');
        return !!(v && !v.paused && !v.ended);
      })();
    ''');
    return result.toString().replaceAll('"', '').trim() == 'true';
  }

  Future<void> _pauseWebVideo() async {
    try {
      await _controller.runJavaScript('''
        (function() {
          var v = document.querySelector('video');
          if (v) v.pause();
        })();
      ''');
    } catch (_) {
      // 백그라운드에서 웹뷰가 이미 얼어 있으면 무시.
    }
  }

  Future<String?> _currentVideoId() async {
    final videoId = await _controller.runJavaScriptReturningResult(r'''
      (function() {
        var url = window.location.href;
        var match = url.match(/[?&]v=([\w-]+)/);
        if (!match) match = url.match(/\/shorts\/([\w-]+)/);
        if (!match) match = url.match(/\/embed\/([\w-]+)/);
        return match ? match[1] : null;
      })();
    ''');

    final vid = videoId.toString().replaceAll('"', '').trim();
    if (vid.isEmpty || vid == 'null') return null;
    return vid;
  }

  Future<String?> _safeCurrentVideoId() async {
    try {
      final vid = await _currentVideoId();
      if (vid != null) {
        _lastKnownWebVideoId = vid;
      }
    } catch (_) {
      // Keep the last known foreground video id.
    }
    return _lastKnownWebVideoId;
  }

  Future<double> _currentVideoPosition() async {
    final position = await _controller.runJavaScriptReturningResult('''
      (function() {
        var v = document.querySelector('video');
        return v ? v.currentTime : 0;
      })();
    ''');
    return double.tryParse(position.toString()) ?? 0;
  }

  Future<bool> _shouldContinueWebVideoInBackground() async {
    final playing = await _controller.runJavaScriptReturningResult(r'''
      (function() {
        var v = document.querySelector('video');
        if (!v) return false;

        var now = Date.now();
        var currentlyPlaying = !v.paused && !v.ended && v.readyState > 2;
        var recentlyPlaying =
          !!window.__backtubeVideoWasPlaying &&
          !window.__backtubeVideoEnded &&
          (now - (window.__backtubeLastPlayingAt || 0) < 8000);

        return currentlyPlaying || recentlyPlaying;
      })();
    ''');
    return playing.toString().replaceAll('"', '').trim() == 'true';
  }

  Future<void> _injectPlaybackStateTracker() async {
    await _controller.runJavaScript(r"""
(function() {
  function markPlaying(video) {
    window.__backtubeVideoWasPlaying = true;
    window.__backtubeVideoEnded = false;
    window.__backtubeLastPlayingAt = Date.now();
    if (video) video.dataset.backtubeUserPaused = '0';
  }

  function markStopped(video) {
    if (!video) return;
    window.__backtubeVideoEnded = !!video.ended;
    if (video.ended) {
      window.__backtubeVideoWasPlaying = false;
    }
  }

  function attach(video) {
    if (!video || video.dataset.backtubePlaybackTracker === '1') return;
    video.dataset.backtubePlaybackTracker = '1';
    video.addEventListener('play', function() { markPlaying(video); }, true);
    video.addEventListener('playing', function() { markPlaying(video); }, true);
    video.addEventListener('timeupdate', function() {
      if (!video.paused && !video.ended) markPlaying(video);
    }, true);
    video.addEventListener('pause', function() { markStopped(video); }, true);
    video.addEventListener('ended', function() { markStopped(video); }, true);

    if (!video.paused && !video.ended) markPlaying(video);
  }

  function scan() {
    var videos = document.querySelectorAll('video');
    for (var i = 0; i < videos.length; i++) attach(videos[i]);
  }

  scan();
  if (!window.__backtubePlaybackTrackerObserver) {
    window.__backtubePlaybackTrackerObserver = new MutationObserver(scan);
    window.__backtubePlaybackTrackerObserver.observe(
      document.documentElement || document.body,
      { childList: true, subtree: true }
    );
  }
})();
""");
  }

  Future<void> _startBackgroundAudioIfNeeded({
    bool allowWebViewProbe = false,
  }) async {
    _btLog(
      'startBackgroundAudioIfNeeded '
      'allowWebViewProbe=$allowWebViewProbe '
      'prepared=$_backgroundAudioPrepared '
      'loading=$_backgroundAudioLoading '
      'playerPlaying=${_player.playing} '
      'lastWasPlaying=$_lastKnownWebVideoWasPlaying '
      'lastVideoId=$_lastKnownWebVideoId '
      'backgroundVideoId=$_backgroundVideoId '
      'lastPosition=$_lastKnownWebPosition',
    );
    if (_player.playing) return;

    try {
      if (allowWebViewProbe) {
        // 웹뷰가 아직 살아 있을 때 항상 최신 재생 상태/위치를 읽어 온다.
        // (3초 주기 타이머 값은 최대 3초 지난 위치라 그대로 쓰면 점프가 생긴다.)
        // 로딩 중이더라도 위치는 갱신해 둬야 로딩 완료 후 제 위치에서 시작한다.
        try {
          _lastKnownWebVideoWasPlaying =
              await _shouldContinueWebVideoInBackground();
          if (_lastKnownWebVideoWasPlaying) {
            await _safeCurrentVideoId();
            await _safeCurrentVideoPosition();
          }
        } catch (_) {
          // 웹뷰가 이미 얼었으면 마지막으로 알던 상태를 그대로 쓴다.
        }
        _btLog(
          'webview probe result lastWasPlaying=$_lastKnownWebVideoWasPlaying '
          'lastVideoId=$_lastKnownWebVideoId '
          'lastPosition=$_lastKnownWebPosition',
        );
      }

      if (_backgroundAudioLoading) {
        _btLog('background audio is loading; will play when prepared');
        _playWhenPrepared = true;
        return;
      }

      if (!_lastKnownWebVideoWasPlaying) {
        _btLog('skip background audio: last known web video was not playing');
        return;
      }
      final position = _lastKnownWebPosition;
      if (_lastKnownWebVideoId != null &&
          _backgroundAudioPrepared &&
          _backgroundVideoId == _lastKnownWebVideoId) {
        _btLog('using prepared player; seek=$position then play');
        await _player.seek(position);
        await _activateAudioSession();
        await _player.play();
        unawaited(_pauseWebVideo());
        if (mounted) {
          setState(() {
            _audioPlaying = true;
          });
        }
        return;
      }

      _btLog('prepared player unavailable/mismatched; preparing now');
      _playWhenPrepared = true;
      await _handleBackgroundAudio(playAfterPrepare: true);
    } catch (e, st) {
      _btLog('startBackgroundAudioIfNeeded error: $e\n$st');
    }
  }

  Future<void> _handleBackgroundAudio({bool playAfterPrepare = true}) async {
    if (_audioLoading || _backgroundAudioLoading) return;
    if (mounted) {
      setState(() {
        _audioLoading = true;
      });
    }

    try {
      final vid = await _safeCurrentVideoId();
      if (vid == null) return;

      final pos = await _safeCurrentVideoPosition();
      await _prepareBackgroundAudio(
        videoId: vid,
        position: pos,
        playAfterPrepare: playAfterPrepare,
      );
    } finally {
      if (mounted) {
        setState(() {
          _audioLoading = false;
        });
      }
    }
  }

  Future<Duration> _safeCurrentVideoPosition() async {
    try {
      final seconds = await _currentVideoPosition();
      _lastKnownWebPosition = Duration(milliseconds: (seconds * 1000).round());
    } catch (_) {
      // Keep the last known foreground position.
    }
    return _lastKnownWebPosition;
  }

  Future<void> _prepareBackgroundAudioWhileForeground() async {
    if (_isInBackground || _backgroundAudioLoading) return;

    try {
      _lastKnownWebVideoWasPlaying =
          await _shouldContinueWebVideoInBackground();
      if (!_lastKnownWebVideoWasPlaying) {
        _btLog('foreground prepare skipped: web video not playing');
        return;
      }

      final vid = await _safeCurrentVideoId();
      if (vid == null) {
        _btLog('foreground prepare skipped: video id is null');
        return;
      }

      final position = await _safeCurrentVideoPosition();
      if (_backgroundAudioPrepared && _backgroundVideoId == vid) {
        _btLog(
            'foreground prepare already ready: videoId=$vid position=$position');
        return;
      }

      _btLog('foreground prepare start: videoId=$vid position=$position');
      await _prepareBackgroundAudio(
        videoId: vid,
        position: position,
        playAfterPrepare: false,
      );
    } catch (e, st) {
      _btLog('foreground prepare error: $e\n$st');
    }
  }

  Future<void> _prepareBackgroundAudio({
    required String videoId,
    required Duration position,
    required bool playAfterPrepare,
  }) async {
    if (_backgroundAudioLoading) return;
    _backgroundAudioLoading = true;

    YoutubeExplode? yt;
    try {
      _btLog(
        'prepareBackgroundAudio start '
        'videoId=$videoId position=$position playAfterPrepare=$playAfterPrepare',
      );
      yt = YoutubeExplode();
      final video = await yt.videos.get(videoId);
      final mediaItem = MediaItem(
        id: videoId,
        title: video.title,
        artist: video.author,
        duration: video.duration,
        artUri: Uri.parse(video.thumbnails.highResUrl),
      );

      // 플레이어는 재생성하지 않고 재사용한다. just_audio_background는
      // 단일 인스턴스 전제라서, dispose 후 재생성하면 iOS 오디오 세션과
      // 알림(제어센터) 바인딩이 끊겨 백그라운드 재생이 중단될 수 있다.
      _backgroundAudioPrepared = false;
      _backgroundVideoId = videoId;
      _backgroundMediaItem = mediaItem;
      final loaded = await _loadPlayableAudio(
        yt: yt,
        videoId: videoId,
        mediaItem: mediaItem,
        position: position,
      );
      if (!loaded) {
        _btLog('prepareBackgroundAudio: all stream candidates failed');
        if (_isInBackground) {
          unawaited(_endIosBackgroundGrace());
        }
        return;
      }
      _btLog(
        'setAudioSource done duration=${_player.duration} '
        'processing=${_player.processingState}',
      );
      _backgroundAudioPrepared = true;

      // 백그라운드일 때만 자동 재생한다. 로딩 중에 포그라운드로 복귀했다면
      // 웹 영상이 다시 재생될 수 있으므로 여기서 소리를 내면 이중 재생이 된다.
      final shouldPlayNow =
          (playAfterPrepare || _playWhenPrepared) && _isInBackground;
      _playWhenPrepared = false;
      if (!shouldPlayNow) {
        _btLog('prepared without play');
        return;
      }

      // 로딩하는 동안 백그라운드 진입 probe가 더 최신 위치를 알아냈다면
      // 그 위치에서 시작한다. (준비 시작 시점 위치는 이미 수 초 지났을 수 있다.)
      var startPosition = position;
      if ((_lastKnownWebPosition - position).abs() >
          const Duration(seconds: 1)) {
        startPosition = _lastKnownWebPosition;
        await _player.seek(startPosition);
      }

      _btLog('play prepared audio start position=$startPosition');
      // iOS: 백그라운드 전환 중에는 재생 시작 전에 오디오 세션을 먼저
      // 활성화해야 앱이 suspend 되지 않고 재생이 이어진다.
      await _activateAudioSession();
      await _player.play();
      _btLog(
        'play returned playing=${_player.playing} '
        'processing=${_player.processingState} '
        'position=${_player.position}',
      );

      await Future<void>.delayed(const Duration(milliseconds: 300));
      if (!_player.playing) {
        _btLog('play retry after 300ms');
        await _player.play();
      }
      if (_isInBackground && _player.playing) {
        unawaited(_pauseWebVideo());
      }
      if (mounted && _player.playing) {
        setState(() {
          _audioPlaying = true;
        });
      }
    } catch (e, st) {
      _btLog('prepareBackgroundAudio error: $e\n$st');
    } finally {
      yt?.close();
      _backgroundAudioLoading = false;
    }
  }

  /// 유튜브 클라이언트를 순서대로 시도해 실제 플레이어 로드까지 성공하는
  /// 스트림을 찾는다. 영상마다 살아있는 클라이언트가 다르다:
  /// - IOS 클라이언트 URL이 AVPlayer(AppleCoreMedia UA)와 가장 잘 맞지만,
  ///   일부 영상은 IOS 매니페스트 자체가 403으로 거부된다.
  /// - 기본(ANDROID) URL은 매니페스트는 나오지만 AVPlayer가 로드하지 못하는
  ///   경우가 있어 마지막 폴백으로만 쓴다.
  /// 매니페스트 URL이 HTTP로는 살아 있어도 AVPlayer가 거부할 수 있으므로,
  /// setAudioSource(실제 로드) 성공까지를 검증 기준으로 삼는다.
  Future<bool> _loadPlayableAudio({
    required YoutubeExplode yt,
    required String videoId,
    required MediaItem mediaItem,
    required Duration position,
  }) async {
    final attempts = <(String, List<YoutubeApiClient>?)>[
      ('ios', [YoutubeApiClient.ios]),
      ('androidVr', [YoutubeApiClient.androidVr]),
      ('default', null),
    ];

    for (final (label, clients) in attempts) {
      try {
        final manifest = clients == null
            ? await yt.videos.streamsClient.getManifest(videoId)
            : await yt.videos.streamsClient
                .getManifest(videoId, ytClients: clients);
        final audio = _selectIosPlayableAudio(manifest);
        _btLog(
          'candidate[$label] container=${audio.container} '
          'codec=${audio.audioCodec} bitrate=${audio.bitrate}',
        );
        await _player.setAudioSource(
          AudioSource.uri(audio.url, tag: mediaItem),
          initialPosition: position,
        );
        _btLog('candidate[$label] loaded ok');
        _scheduleManifestRefresh(audio.url);
        return true;
      } on PlayerInterruptedException {
        // 더 새로운 로드가 시작된 것이므로 이 시도는 조용히 중단한다.
        _btLog('candidate[$label] interrupted by newer load');
        return false;
      } catch (e) {
        _btLog('candidate[$label] failed: $e');
      }
    }
    return false;
  }

  AudioOnlyStreamInfo _selectIosPlayableAudio(StreamManifest manifest) {
    final mp4Audio = manifest.audioOnly
        .where((stream) => stream.container == StreamContainer.mp4);
    if (mp4Audio.isNotEmpty) {
      final selected = mp4Audio.withHighestBitrate();
      _btLog(
          'audio candidates mp4=${mp4Audio.length} all=${manifest.audioOnly.length}');
      return selected;
    }
    _btLog('audio candidates no mp4; all=${manifest.audioOnly.length}');
    return manifest.audioOnly.withHighestBitrate();
  }

  Duration _refreshDelayFor(Uri streamUrl) {
    final expireSeconds =
        int.tryParse(streamUrl.queryParameters['expire'] ?? '');
    if (expireSeconds == null) return const Duration(hours: 1);

    final expiresAt = DateTime.fromMillisecondsSinceEpoch(
      expireSeconds * 1000,
      isUtc: false,
    );
    // 실제 만료 10분 전에만 소스를 교체한다. 소스 교체는 짧은 끊김을
    // 만들기 때문에 (기존 45분 캡처럼) 불필요하게 자주 하면 안 된다.
    final delay =
        expiresAt.difference(DateTime.now()) - const Duration(minutes: 10);

    if (delay < const Duration(minutes: 1)) return const Duration(minutes: 1);
    return delay;
  }

  void _scheduleManifestRefresh(Uri streamUrl) {
    _manifestRefreshTimer?.cancel();
    _manifestRefreshTimer = Timer(_refreshDelayFor(streamUrl), () {
      _refreshBackgroundAudioSource();
    });
  }

  Future<void> _refreshBackgroundAudioSource() async {
    final vid = _backgroundVideoId;
    final mediaItem = _backgroundMediaItem;
    if (vid == null || mediaItem == null) return;
    if (_backgroundAudioLoading) return;

    _backgroundAudioLoading = true;
    YoutubeExplode? yt;
    try {
      _btLog('refresh manifest start videoId=$vid');
      final position = _player.position;
      final wasPlaying = _player.playing;
      yt = YoutubeExplode();
      final loaded = await _loadPlayableAudio(
        yt: yt,
        videoId: vid,
        mediaItem: mediaItem,
        position: position,
      );
      if (!loaded) {
        throw Exception('refresh: all stream candidates failed');
      }

      if (wasPlaying) {
        await _player.play();
      }
    } catch (e, st) {
      _btLog('refresh manifest error: $e\n$st');
      _manifestRefreshTimer?.cancel();
      _manifestRefreshTimer = Timer(const Duration(minutes: 5), () {
        _refreshBackgroundAudioSource();
      });
    } finally {
      yt?.close();
      _backgroundAudioLoading = false;
    }
  }

  void _attachPlayerDebugLogs(AudioPlayer player) {
    _playerStateSubscription = player.playerStateStream.listen(
      (state) {
        _btLog(
          'playerState videoId=$_backgroundVideoId '
          'playing=${state.playing} '
          'processing=${state.processingState} '
          'position=${player.position} '
          'duration=${player.duration}',
        );
        // 재생이 실제로 시작되면 audio 백그라운드 모드가 앱을 유지하므로
        // beginBackgroundTask 유예는 반납한다.
        if (state.playing &&
            state.processingState == ProcessingState.ready) {
          unawaited(_endIosBackgroundGrace());
        }
      },
      onError: (Object e, StackTrace st) {
        _btLog('playerState error: $e\n$st');
        _recoverFromPlaybackError();
      },
    );

    _playbackEventSubscription = player.playbackEventStream.listen(
      (event) {
        _btLog(
          'playbackEvent videoId=$_backgroundVideoId '
          'processing=${event.processingState} '
          'updatePosition=${event.updatePosition} '
          'buffered=${event.bufferedPosition} '
          'duration=${event.duration} '
          'currentIndex=${event.currentIndex}',
        );
      },
      onError: (Object e, StackTrace st) {
        _btLog('playbackEvent error: $e\n$st');
        _recoverFromPlaybackError();
      },
    );
  }

  /// 스트림 URL 만료(403 등)로 재생이 죽으면 새 매니페스트로 즉시 복구한다.
  void _recoverFromPlaybackError() {
    if (_backgroundAudioLoading) return;
    if (_backgroundVideoId == null) return;
    _manifestRefreshTimer?.cancel();
    _manifestRefreshTimer = Timer(const Duration(seconds: 1), () {
      _refreshBackgroundAudioSource();
    });
  }

  void _btLog(String message) {
    debugPrint('[BT] $message');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Stack(
          children: [
            // WebView는 항상 터치 이벤트를 100% 받도록 직접 배치
            WebViewWidget(controller: _controller),
            // 스크롤을 방해하지 않고 수평 스와이프만 감지
            Positioned.fill(
              child: Listener(
                behavior: HitTestBehavior.translucent,
                onPointerDown: _onPointerDown,
                onPointerUp: _onPointerUp,
              ),
            ),
            if (_audioPlaying)
              Positioned(
                left: 0,
                right: 0,
                bottom: 24,
                child: Center(
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.7),
                      borderRadius: BorderRadius.circular(32),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          icon: Icon(
                              _player.playing
                                  ? Icons.pause
                                  : Icons.play_arrow,
                              color: Colors.white),
                          onPressed: () async {
                            if (_player.playing) {
                              await _player.pause();
                            } else {
                              await _player.play();
                            }
                            setState(() {});
                          },
                        ),
                        IconButton(
                          icon: const Icon(Icons.close, color: Colors.white),
                          onPressed: () async {
                            _manifestRefreshTimer?.cancel();
                            _backgroundVideoId = null;
                            _backgroundMediaItem = null;
                            _backgroundAudioPrepared = false;
                            _playWhenPrepared = false;
                            _lastKnownWebVideoWasPlaying = false;
                            // dispose 하지 않고 stop만 한다.
                            // 플레이어를 없애면 다음 백그라운드 전환 때
                            // 오디오 세션을 다시 만들며 재생이 늦어진다.
                            await _player.stop();
                            setState(() {
                              _audioPlaying = false;
                            });
                          },
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            if (_audioLoading)
              Positioned(
                left: 0,
                right: 0,
                bottom: 80,
                child: Center(
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.5),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: const Text('오디오 준비중...',
                        style: TextStyle(color: Colors.white)),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
