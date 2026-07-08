import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:just_audio/just_audio.dart';
import 'package:audio_session/audio_session.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';
import 'package:just_audio_background/just_audio_background.dart';

import 'download_service.dart';
import 'home_menu_page.dart';
import 'player_service.dart';

Future<void> main() async {
  debugPrint('[BT] boot: main() entered');
  WidgetsFlutterBinding.ensureInitialized();
  debugPrint('[BT] boot: WidgetsFlutterBinding ready');
  // just_audio_background(내부 audio_service)는 runApp 전에 초기화가 끝나 있어야
  // 안전하다. 실패하더라도 앱 화면은 떠야 하므로 try/catch로 감싼다.
  try {
    debugPrint('[BT] boot: ensureAudioReady begin');
    await ensureAudioReady();
    debugPrint('[BT] boot: ensureAudioReady done');
  } catch (e, st) {
    debugPrint('[BT] audio init failed: $e\n$st');
  }
  debugPrint('[BT] boot: runApp');
  runApp(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.dark,
      darkTheme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFFFF0033),
          brightness: Brightness.dark,
        ),
      ),
      home: const HomeMenuPage(),
    ),
  );
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
  // 이 화면이 dispose된 뒤에도, 진행 중이던 유튜브 오디오 준비 작업이
  // 뒤늦게 공유 btPlayer를 건드려(setAudioSource/stop) 저장파일 재생을
  // 덮어쓰거나 정지시키지 않도록 하는 플래그.
  bool _disposed = false;
  // 프리페어가 실패한 영상 id. 봇 차단/재생 불가 영상을 3초마다 반복 시도해
  // AVPlayer XPC를 계속 크래시시키지 않도록, 같은 영상은 한 번만 시도한다.
  String? _failedPrepareVideoId;
  bool _lastKnownWebVideoWasPlaying = false;
  Duration _lastKnownWebPosition = Duration.zero;
  // 웹 플레이어에서 사용자가 고른 배속(예: 1.5x). 백그라운드 오디오는 웹 영상이
  // 아니라 별도 _player로 재생되므로, 이 값을 setSpeed로 넘겨주지 않으면
  // 항상 1.0배속으로 떨어진다.
  double _lastKnownWebPlaybackRate = 1.0;
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
    // 앱 전역 공유 인스턴스(btPlayer)를 재사용한다. 메뉴에서 이 화면을
    // 오갈 때마다 새로 만들면 iOS 오디오 세션/알림 바인딩이 끊긴다.
    _player = btPlayer;
    _attachPlayerDebugLogs(_player);
    _setupAudioSessionHandlers();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..addJavaScriptChannel(_jsChannelName, onMessageReceived: (msg) async {
        // 유튜브 "공유" 클릭 → 오디오 저장 메뉴.
        if (msg.message.startsWith('share:')) {
          final sharedUrl = msg.message.substring('share:'.length);
          await _handleShareSaveRequest(sharedUrl);
          return;
        }
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
          await _injectShareInterceptor();
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
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    _foregroundPrepareTimer?.cancel();
    _manifestRefreshTimer?.cancel();
    _playerStateSubscription?.cancel();
    _playbackEventSubscription?.cancel();
    _interruptionSubscription?.cancel();
    _becomingNoisySubscription?.cancel();
    // _player(btPlayer)는 앱 전역 공유 인스턴스라 여기서 dispose 하지 않는다.
    // (메뉴로 돌아가도 백그라운드 재생/알림이 유지되어야 한다.)
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
        final rate = _lastKnownWebPlaybackRate;
        await _controller.runJavaScript('''
          (function() {
            var v = document.querySelector('video');
            if (v) {
              try { v.currentTime = $seconds; } catch (e) {}
              try { v.playbackRate = $rate; } catch (e) {}
            }
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

  Future<double> _currentVideoPlaybackRate() async {
    final rate = await _controller.runJavaScriptReturningResult('''
      (function() {
        var v = document.querySelector('video');
        return v ? v.playbackRate : 1;
      })();
    ''');
    return double.tryParse(rate.toString()) ?? 1.0;
  }

  /// 백그라운드 오디오(_player)의 배속을 웹 플레이어에서 고른 값에 맞춘다.
  Future<void> _applyBackgroundPlaybackSpeed() async {
    final rate = _lastKnownWebPlaybackRate;
    if (rate <= 0) return;
    if ((_player.speed - rate).abs() < 0.01) return;
    try {
      await _player.setSpeed(rate);
      _btLog('applied background speed=$rate');
    } catch (e) {
      _btLog('setSpeed error: $e');
    }
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

  /// 유튜브 공유 동작을 가로채 Flutter로 알린다.
  /// (1) Web Share API(navigator.share) 오버라이드 — iOS 유튜브 공유의 주 경로.
  /// (2) '공유'/'share' 버튼 클릭 감지 — navigator.share를 안 쓰는 경우 대비.
  Future<void> _injectShareInterceptor() async {
    await _controller.runJavaScript(r"""
(function() {
  if (window.__btShareHooked) return;
  window.__btShareHooked = true;

  function postShare(url) {
    try {
      var now = Date.now();
      if (window.__btLastShareAt && (now - window.__btLastShareAt) < 1500) return;
      window.__btLastShareAt = now;
      FullscreenListener.postMessage('share:' + (url || window.location.href));
    } catch (e) {}
  }

  try {
    navigator.share = function(data) {
      var u = (data && (data.url || data.text)) || window.location.href;
      postShare(u);
      return Promise.resolve();
    };
  } catch (e) {}

  document.addEventListener('click', function(e) {
    try {
      var el = (e.target && e.target.closest)
        ? e.target.closest('[aria-label], button, a')
        : null;
      if (!el) return;
      var label = (el.getAttribute('aria-label') || el.textContent || '')
        .toLowerCase();
      if (label.indexOf('공유') >= 0 || label.indexOf('share') >= 0) {
        postShare(window.location.href);
      }
    } catch (e) {}
  }, true);
})();
""");
  }

  String? _extractVideoIdFromUrl(String url) {
    final patterns = <RegExp>[
      RegExp(r'youtu\.be/([\w-]{6,})'),
      RegExp(r'[?&]v=([\w-]{6,})'),
      RegExp(r'/shorts/([\w-]{6,})'),
      RegExp(r'/embed/([\w-]{6,})'),
    ];
    for (final p in patterns) {
      final m = p.firstMatch(url);
      if (m != null) return m.group(1);
    }
    return null;
  }

  Future<void> _handleShareSaveRequest(String sharedUrl) async {
    _btLog('share intent url=$sharedUrl');
    // 공유 URL에서 videoId 우선 파싱, 없으면 현재 재생 중인 영상 id.
    var videoId = _extractVideoIdFromUrl(sharedUrl);
    videoId ??= await _safeCurrentVideoId();
    if (!mounted) return;
    if (videoId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('영상을 찾을 수 없습니다.')),
      );
      return;
    }
    _showSaveSheet(videoId);
  }

  void _showSaveSheet(String videoId) {
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text('이 영상을',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            ),
            ListTile(
              leading: const Icon(Icons.audiotrack),
              title: const Text('오디오로 저장 (m4a)'),
              subtitle: const Text('저장파일 메뉴에서 백그라운드 재생'),
              onTap: () {
                Navigator.pop(ctx);
                _startDownload(videoId);
              },
            ),
            ListTile(
              leading: const Icon(Icons.close),
              title: const Text('취소'),
              onTap: () => Navigator.pop(ctx),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _startDownload(String videoId) async {
    if (await DownloadService.isSaved(videoId)) {
      if (!mounted) return;
      final overwrite = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('이미 저장됨'),
          content: const Text('이 영상은 이미 저장되어 있습니다. 다시 저장할까요?'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('취소')),
            TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('다시 저장')),
          ],
        ),
      );
      if (overwrite != true) return;
    }

    // 전체 크기를 모르는 스트림도 있어 progress는 nullable(불확정) + 받은 용량 표시.
    final progress = ValueNotifier<double?>(null);
    final label = ValueNotifier<String>('준비 중...');
    if (mounted) {
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          title: const Text('오디오 저장 중...'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ValueListenableBuilder<double?>(
                valueListenable: progress,
                builder: (_, v, __) => LinearProgressIndicator(value: v),
              ),
              const SizedBox(height: 12),
              ValueListenableBuilder<String>(
                valueListenable: label,
                builder: (_, v, __) => Text(v),
              ),
            ],
          ),
        ),
      );
    }

    try {
      final saved = await DownloadService.saveAudio(
        videoId,
        onBytes: (received, total) {
          progress.value = total > 0 ? received / total : null;
          label.value = total > 0
              ? '${_fmtMb(received)} / ${_fmtMb(total)} MB'
              : '${_fmtMb(received)} MB 받는 중...';
        },
      ).timeout(const Duration(minutes: 5));
      if (mounted) {
        Navigator.of(context, rootNavigator: true).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('저장 완료: ${saved.title}')),
        );
      }
    } catch (e) {
      _btLog('save audio error: $e');
      if (mounted) {
        Navigator.of(context, rootNavigator: true).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('저장 실패: $e')),
        );
      }
    } finally {
      progress.dispose();
      label.dispose();
    }
  }

  String _fmtMb(int bytes) => (bytes / (1024 * 1024)).toStringAsFixed(1);

  Future<void> _startBackgroundAudioIfNeeded({
    bool allowWebViewProbe = false,
  }) async {
    if (_disposed) return;
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
        await _applyBackgroundPlaybackSpeed();
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
    if (_disposed || _audioLoading || _backgroundAudioLoading) return;
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
      final rate = await _currentVideoPlaybackRate();
      if (rate > 0) _lastKnownWebPlaybackRate = rate;
    } catch (_) {
      // Keep the last known foreground position/speed.
    }
    return _lastKnownWebPosition;
  }

  Future<void> _prepareBackgroundAudioWhileForeground() async {
    if (_disposed || _isInBackground || _backgroundAudioLoading) return;

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

      if (vid == _failedPrepareVideoId) {
        _btLog('foreground prepare skipped: video previously failed ($vid)');
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
    if (_disposed || _backgroundAudioLoading) return;
    _backgroundAudioLoading = true;

    YoutubeExplode? yt;
    try {
      _btLog(
        'prepareBackgroundAudio start '
        'videoId=$videoId position=$position playAfterPrepare=$playAfterPrepare '
        'isInBackground=$_isInBackground playWhenPrepared=$_playWhenPrepared',
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
        // 실패한 로드로 플레이어가 broken/playing 상태로 남아 이후 저장파일
        // 재생을 방해하지 않도록 깨끗이 정지시킨다.
        try {
          await _player.stop();
        } catch (_) {}
        // 봇 차단/재생 불가 영상은 3초 타이머로 반복 시도하지 않는다.
        _failedPrepareVideoId = videoId;
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
      _failedPrepareVideoId = null;

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
      await _applyBackgroundPlaybackSpeed();
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
    if (_disposed) return false;
    final attempts = <(String, List<YoutubeApiClient>?)>[
      ('ios', [YoutubeApiClient.ios]),
      ('androidVr', [YoutubeApiClient.androidVr]),
      ('default', null),
    ];

    // 백그라운드에서 AVPlayer가 미디어를 로드/디코드하려면 오디오 세션이
    // 먼저 활성화돼 있어야 한다. 세션이 죽어 있으면 setAudioSource가
    // -11800/-11819로 실패한다.
    if (_isInBackground) {
      _btLog('loadPlayableAudio: activating session before load (background)');
      await _activateAudioSession();
    }

    for (final (label, clients) in attempts) {
      final StreamManifest manifest;
      try {
        manifest = clients == null
            ? await yt.videos.streamsClient.getManifest(videoId)
            : await yt.videos.streamsClient
                .getManifest(videoId, ytClients: clients);
      } catch (e) {
        _btLog('candidate[$label] manifest failed: $e');
        continue;
      }

      final candidates = _orderedAudioCandidates(manifest);
      _btLog(
        'candidate[$label] manifest ok; audio streams='
        '${candidates.map((s) => '${s.container.name}/${s.audioCodec}'
            '@${s.bitrate.kiloBitsPerSecond.round()}k').join(', ')}',
      );

      for (var i = 0; i < candidates.length; i++) {
        final audio = candidates[i];
        final expire = audio.url.queryParameters['expire'] ?? '?';
        _btLog(
          'try[$label#$i] container=${audio.container} '
          'codec=${audio.audioCodec} bitrate=${audio.bitrate} '
          'host=${audio.url.host} expire=$expire background=$_isInBackground',
        );
        try {
          // 화면이 내려간 뒤라면 공유 플레이어를 건드리지 않는다.
          // (저장파일 재생이 이미 이 플레이어를 쓰고 있을 수 있다.)
          if (_disposed) return false;
          final loadedDuration = await _player.setAudioSource(
            AudioSource.uri(audio.url, tag: mediaItem),
            initialPosition: position,
          );
          // setAudioSource가 예외 없이 끝나도 iOS에서 duration이 비거나 0이면
          // 실제로는 재생 불가한 URL이다(로그의 ready→idle 패턴). 다음 후보로.
          if (loadedDuration == null || loadedDuration == Duration.zero) {
            _btLog(
              'try[$label#$i] loaded but duration=$loadedDuration; '
              'treat as unplayable, next candidate',
            );
            continue;
          }
          _btLog('try[$label#$i] loaded ok duration=$loadedDuration');
          btPlaybackOrigin = BtPlaybackOrigin.web;
          _scheduleManifestRefresh(audio.url);
          return true;
        } on PlayerInterruptedException {
          // 더 새로운 로드가 시작된 것이므로 이 시도는 조용히 중단한다.
          _btLog('try[$label#$i] interrupted by newer load');
          return false;
        } catch (e) {
          _btLog(
            'try[$label#$i] failed: $e '
            '(processing=${_player.processingState})',
          );
          // 실패한 로드는 AVPlayer 내부 상태(특히 XPC 파이프라인)를 흔들어
          // 놓을 수 있어, 다음 후보 로드가 연쇄 실패(-11819)한다. stop으로
          // 플레이어를 idle로 되돌려 다음 시도가 깨끗한 상태에서 시작하게 한다.
          try {
            await _player.stop();
          } catch (_) {}
        }
      }
    }
    return false;
  }

  /// 오디오 후보를 재생 우선순위대로 정렬한다. mp4(AAC)를 고비트레이트부터.
  /// iOS AVPlayer는 webm/opus를 재생하지 못하므로(무조건 -11828 실패 + XPC
  /// 크래시 유발) iOS에서는 mp4만 후보로 둔다. Android(ExoPlayer)는 opus도 재생
  /// 가능하므로 폴백으로 유지한다.
  List<AudioOnlyStreamInfo> _orderedAudioCandidates(StreamManifest manifest) {
    int byBitrateDesc(AudioOnlyStreamInfo a, AudioOnlyStreamInfo b) =>
        b.bitrate.bitsPerSecond.compareTo(a.bitrate.bitsPerSecond);

    final all = manifest.audioOnly.toList();
    final mp4 = all
        .where((s) => s.container == StreamContainer.mp4)
        .toList()
      ..sort(byBitrateDesc);
    final others = all
        .where((s) => s.container != StreamContainer.mp4)
        .toList()
      ..sort(byBitrateDesc);
    _btLog('orderedAudioCandidates mp4=${mp4.length} other=${others.length} '
        'iOS=${Platform.isIOS}');
    if (Platform.isIOS) return mp4;
    return [...mp4, ...others];
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
    if (_disposed) return;
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

      // 소스 교체 후에도 배속이 유지되도록 다시 적용한다.
      await _applyBackgroundPlaybackSpeed();
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
