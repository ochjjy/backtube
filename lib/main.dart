

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:just_audio/just_audio.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';
import 'package:just_audio_background/just_audio_background.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await JustAudioBackground.init(
    androidNotificationChannelId: 'com.example.backtube.channel.audio',
    androidNotificationChannelName: 'BackTube Audio Playback',
    androidNotificationOngoing: true,
  );
  runApp(const MaterialApp(home: WebViewPage()));
}

class WebViewPage extends StatefulWidget {
  const WebViewPage({super.key});

  @override
  State<WebViewPage> createState() => _WebViewPageState();
}

class _WebViewPageState extends State<WebViewPage> with WidgetsBindingObserver {
  AudioPlayer? _player;
  bool _audioLoading = false;
  bool _audioPlaying = false;
  late final WebViewController _controller;
  static const String _jsChannelName = 'FullscreenListener';

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
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..addJavaScriptChannel(_jsChannelName, onMessageReceived: (msg) async {
        // 전체화면 버튼 또는 영상 클릭 시 오디오 플레이어로 이동
        await _handleBackgroundAudio();
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
                }
              }
              setInterval(function() { addFSListener(); addVideoListener(); }, 1000);
            })();
          ''');
        },
      ))
      ..loadRequest(Uri.parse('https://m.youtube.com'));
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 백그라운드 진입 시 자동 오디오 재생은 비활성화 (전체화면 버튼에서만 동작)
  }

  Future<void> _handleBackgroundAudio() async {
    if (_audioLoading) return;
    setState(() { _audioLoading = true; });
    final videoId = await _controller.runJavaScriptReturningResult('''
      (function() {
        var url = window.location.href;
        var match = url.match(/v=([\\w-]+)/);
        return match ? match[1] : null;
      })();
    ''');
    final position = await _controller.runJavaScriptReturningResult('''
      (function() {
        var v = document.querySelector('video');
        return v ? v.currentTime : 0;
      })();
    ''');
    final vid = videoId.toString().replaceAll('"', '');
    final pos = double.tryParse(position.toString()) ?? 0;
    if (vid.isNotEmpty && vid != 'null') {
      try {
        final yt = YoutubeExplode();
        final manifest = await yt.videos.streamsClient.getManifest(vid);
        final audio = manifest.audioOnly.withHighestBitrate();
        final url = audio.url.toString();
        _player?.dispose();
        _player = AudioPlayer();
        await _player!.setUrl(url);
        await _player!.seek(Duration(seconds: pos.toInt()));
        await _player!.play();
        setState(() {
          _audioPlaying = true;
        });
        yt.close();
      } catch (e) {
        // ignore
      }
    }
    setState(() { _audioLoading = false; });
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
                left: 0, right: 0, bottom: 24,
                child: Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(0.7),
                      borderRadius: BorderRadius.circular(32),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          icon: Icon(_player?.playing == true ? Icons.pause : Icons.play_arrow, color: Colors.white),
                          onPressed: () async {
                            if (_player == null) return;
                            if (_player!.playing) {
                              await _player!.pause();
                              setState(() { _audioPlaying = false; });
                            } else {
                              await _player!.play();
                              setState(() { _audioPlaying = true; });
                            }
                          },
                        ),
                        IconButton(
                          icon: const Icon(Icons.close, color: Colors.white),
                          onPressed: () async {
                            await _player?.stop();
                            await _player?.dispose();
                            setState(() {
                              _audioPlaying = false;
                              _player = null;
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
                left: 0, right: 0, bottom: 80,
                child: Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(0.5),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: const Text('오디오 준비중...', style: TextStyle(color: Colors.white)),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}