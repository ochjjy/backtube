

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
  runApp(MaterialApp(home: WebViewPage()));
}

class WebViewPage extends StatefulWidget {
  @override
  State<WebViewPage> createState() => _WebViewPageState();
}

class _WebViewPageState extends State<WebViewPage> with WidgetsBindingObserver {
  AudioPlayer? _player;
  bool _audioLoading = false;
  bool _audioPlaying = false;
  String? _currentVideoId;
  bool _showNavButtons = false;
  late DateTime _lastShowTime;
  static const Duration _buttonVisibleDuration = Duration(seconds: 3);
  late final WebViewController _controller;
  static const String _jsChannelName = 'FullscreenListener';

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
        var match = url.match(/v=([\w-]+)/);
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
          _currentVideoId = vid;
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
            // 화면 중앙 1/3 영역에만 투명 더블탭 레이어 (네비게이션 버튼 표시용)
            Positioned(
              left: MediaQuery.of(context).size.width / 3,
              top: MediaQuery.of(context).size.height / 3,
              width: MediaQuery.of(context).size.width / 3,
              height: MediaQuery.of(context).size.height / 3,
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onDoubleTap: () {
                  setState(() {
                    _showNavButtons = true;
                    _lastShowTime = DateTime.now();
                  });
                  Future.delayed(_buttonVisibleDuration, () {
                    if (mounted && DateTime.now().difference(_lastShowTime) >= _buttonVisibleDuration) {
                      setState(() {
                        _showNavButtons = false;
                      });
                    }
                  });
                },
                child: Container(),
              ),
            ),
            if (_showNavButtons)
              Positioned.fill(
                child: IgnorePointer(
                  ignoring: false,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      // < 버튼 (뒤로)
                      Container(
                        alignment: Alignment.centerLeft,
                        child: GestureDetector(
                          onTap: () async {
                            if (await _controller.canGoBack()) _controller.goBack();
                            setState(() => _showNavButtons = false);
                          },
                          child: Container(
                            margin: const EdgeInsets.only(left: 8),
                            padding: const EdgeInsets.symmetric(vertical: 32, horizontal: 16),
                            decoration: BoxDecoration(
                              color: Colors.black.withOpacity(0.3),
                              borderRadius: BorderRadius.circular(32),
                            ),
                            child: const Icon(Icons.arrow_back_ios, color: Colors.white, size: 32),
                          ),
                        ),
                      ),
                      // > 버튼 (앞으로)
                      Container(
                        alignment: Alignment.centerRight,
                        child: GestureDetector(
                          onTap: () async {
                            if (await _controller.canGoForward()) _controller.goForward();
                            setState(() => _showNavButtons = false);
                          },
                          child: Container(
                            margin: const EdgeInsets.only(right: 8),
                            padding: const EdgeInsets.symmetric(vertical: 32, horizontal: 16),
                            decoration: BoxDecoration(
                              color: Colors.black.withOpacity(0.3),
                              borderRadius: BorderRadius.circular(32),
                            ),
                            child: const Icon(Icons.arrow_forward_ios, color: Colors.white, size: 32),
                          ),
                        ),
                      ),
                    ],
                  ),
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
                              _currentVideoId = null;
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