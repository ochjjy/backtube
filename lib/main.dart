import 'dart:async';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'download_service.dart';
import 'home_menu_page.dart';
import 'player_service.dart';

Future<void> main() async {
  debugPrint('[BT] boot: main() entered');
  WidgetsFlutterBinding.ensureInitialized();
  debugPrint('[BT] boot: WidgetsFlutterBinding ready');
  // 오디오 초기화(JustAudioBackground.init + 세션 설정)는 기기에 따라 수 초가
  // 걸린다. runApp 앞에서 await 하면 그 시간만큼 첫 화면이 뜨지 않으므로,
  // 백그라운드로 시작만 하고 첫 프레임을 막지 않는다. btPlayer는 첫 참조 때
  // 생성되고 그 진입(HomeMenuPage._open)이 ensureAudioReady를 await 하므로,
  // 실제 재생 전 초기화 완료는 그대로 보장된다.
  debugPrint('[BT] boot: ensureAudioReady begin (background)');
  unawaited(ensureAudioReady().catchError((Object e, StackTrace st) {
    debugPrint('[BT] audio init failed: $e\n$st');
  }));
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

/// 유튜브 모바일 웹을 띄우는 브라우저 화면.
///
/// 백그라운드 진입 시 유튜브 스트림을 오디오로 이어받아 자동 재생하던 기능은
/// 제거했다. 이 화면은 이제 공유 플레이어(btPlayer)를 건드리지 않으며,
/// 백그라운드 재생은 "오디오로 저장" → 저장파일 화면 재생 경로만 사용한다.
class WebViewPage extends StatefulWidget {
  const WebViewPage({super.key});

  @override
  State<WebViewPage> createState() => _WebViewPageState();
}

class _WebViewPageState extends State<WebViewPage> {
  /// 웹뷰에서 videoId를 읽지 못했을 때(페이지 전환 중 등) 쓰는 마지막 값.
  String? _lastKnownWebVideoId;
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
        // 진단: ⋮ 메뉴에 저장 항목이 실제로 주입됐는지 로그로 확인.
        if (msg.message == 'save_menu_injected') {
          _btLog('save menu item injected into YouTube ⋮ sheet');
          return;
        }
        // 유튜브 ⋮(더보기) 메뉴에 끼워 넣은 "오디오로 저장" 클릭 → 바로 저장.
        if (msg.message.startsWith('save:')) {
          final id = msg.message.substring('save:'.length);
          var videoId = id.isNotEmpty ? id : null;
          videoId ??= await _safeCurrentVideoId();
          if (!mounted) return;
          if (videoId == null) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('영상을 찾을 수 없습니다.')),
            );
            return;
          }
          await _startDownload(videoId);
          return;
        }
        // 유튜브 "공유" 클릭 → 오디오 저장 메뉴(폴백 경로).
        if (msg.message.startsWith('share:')) {
          final sharedUrl = msg.message.substring('share:'.length);
          await _handleShareSaveRequest(sharedUrl);
          return;
        }
      })
      ..setNavigationDelegate(NavigationDelegate(
        onPageFinished: (url) async {
          await _injectShareInterceptor();
          await _injectSaveMenuItem();
        },
      ))
      ..loadRequest(Uri.parse('https://m.youtube.com'));
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

  /// 유튜브 ⋮(더보기) 메뉴 시트에 "오디오로 저장" 항목을 끼워 넣는다.
  /// 시트가 열릴 때 기존 항목(공유/재생목록에 저장 등)을 복제해 스타일을 그대로
  /// 물려받고 텍스트만 교체한다(클래스명 하드코딩을 피해 덜 깨지게 함).
  /// 대상 videoId는 ⋮ 클릭 시점에 근처 watch 링크에서 잡아 둔다.
  /// 주입에 실패해도 기존 '공유' 가로채기(_injectShareInterceptor)가 폴백이 된다.
  Future<void> _injectSaveMenuItem() async {
    await _controller.runJavaScript(r"""
(function() {
  if (window.__btSaveMenuHooked) return;
  window.__btSaveMenuHooked = true;

  function captureVideoId(startEl) {
    var el = startEl;
    for (var i = 0; i < 10 && el; i++, el = el.parentElement) {
      if (!el.querySelector) continue;
      var a = el.querySelector('a[href*="watch?v="], a[href*="/shorts/"], a[href*="youtu.be/"]');
      if (a && a.href) {
        var m = a.href.match(/[?&]v=([\w-]{6,})/) ||
                a.href.match(/\/shorts\/([\w-]{6,})/) ||
                a.href.match(/youtu\.be\/([\w-]{6,})/);
        if (m) { window.__btMenuVideoId = m[1]; return; }
      }
    }
  }

  function labelOf(node) {
    return (((node.getAttribute && node.getAttribute('aria-label')) ||
             node.textContent || '') + '').trim();
  }

  var TARGETS = ['공유','Share','재생목록에 저장','Save to playlist',
                 '나중에 볼 동영상에 저장','Save to Watch Later'];

  function findTemplateItem() {
    var nodes = document.querySelectorAll(
      '[role=menuitem], ytm-menu-item, ytm-bottom-sheet-item, tp-yt-paper-item, .menu-item-button');
    if (!nodes.length) nodes = document.querySelectorAll('a, button, li, div');
    for (var i = 0; i < nodes.length; i++) {
      var t = labelOf(nodes[i]);
      for (var j = 0; j < TARGETS.length; j++) {
        if (t === TARGETS[j]) {
          var item = (nodes[i].closest && nodes[i].closest(
            '[role=menuitem], ytm-menu-item, ytm-bottom-sheet-item, tp-yt-paper-item, li'))
            || nodes[i];
          if (item && item.parentElement) return item;
        }
      }
    }
    return null;
  }

  function replaceText(node, text) {
    try {
      var w = document.createTreeWalker(node, NodeFilter.SHOW_TEXT, null);
      var tn;
      while ((tn = w.nextNode())) {
        if (tn.nodeValue && tn.nodeValue.trim().length) { tn.nodeValue = text; return; }
      }
    } catch (e) {}
    try { node.textContent = text; } catch (e) {}
  }

  function closeSheet() {
    try {
      var back = document.querySelector(
        'tp-yt-iron-overlay-backdrop, .bottom-sheet-scrim, ' +
        '[aria-label="뒤로"], [aria-label="Back"], [aria-label="닫기"], [aria-label="Close"]');
      if (back) back.click();
    } catch (e) {}
  }

  function inject() {
    try {
      if (document.getElementById('bt-save-audio-item')) return true;
      var tmpl = findTemplateItem();
      if (!tmpl) return false;
      var clone = tmpl.cloneNode(true);
      clone.id = 'bt-save-audio-item';
      if (clone.tagName === 'A') clone.removeAttribute('href');
      var links = clone.querySelectorAll ? clone.querySelectorAll('a') : [];
      for (var i = 0; i < links.length; i++) links[i].removeAttribute('href');
      replaceText(clone, '오디오로 저장');
      clone.addEventListener('click', function(e) {
        e.preventDefault(); e.stopPropagation();
        try { FullscreenListener.postMessage('save:' + (window.__btMenuVideoId || '')); } catch (er) {}
        closeSheet();
      }, true);
      tmpl.parentElement.insertBefore(clone, tmpl.parentElement.firstChild);
      try { FullscreenListener.postMessage('save_menu_injected'); } catch (er) {}
      return true;
    } catch (e) { return false; }
  }

  // ⋮(더보기/작업 메뉴)류 버튼 클릭인지. 아무 탭마다 DOM 전체를 스캔하지 않도록
  // 게이트로 쓴다(메뉴와 무관한 탭에서는 주입 시도를 하지 않음).
  function isMenuTrigger(startEl) {
    var el = startEl;
    for (var i = 0; i < 6 && el; i++, el = el.parentElement) {
      var l = labelOf(el).toLowerCase();
      if (l.indexOf('더보기') >= 0 || l.indexOf('작업') >= 0 ||
          l.indexOf('more') >= 0 || l.indexOf('menu') >= 0 ||
          l.indexOf('action') >= 0 || l.indexOf('옵션') >= 0 ||
          l.indexOf('option') >= 0) return true;
    }
    return false;
  }

  // 항목/⋮ 클릭 시 videoId를 잡고, ⋮류면 시트가 렌더된 뒤 주입을 몇 번 시도한다.
  document.addEventListener('click', function(e) {
    captureVideoId(e.target);
    if (!isMenuTrigger(e.target)) return;
    var tries = 0;
    var iv = setInterval(function() {
      if (inject() || ++tries >= 10) clearInterval(iv);
    }, 120);
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
        // 재생 불가/처리 중 등 사용자에게 설명 가능한 사유는 접두어 없이
        // 안내 문구 그대로, 읽을 시간을 주어 보여준다.
        final unavailable = e is AudioUnavailableException;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(unavailable ? '$e' : '저장 실패: $e'),
            duration: unavailable
                ? const Duration(seconds: 6)
                : const Duration(seconds: 4),
          ),
        );
      }
    } finally {
      progress.dispose();
      label.dispose();
    }
  }

  String _fmtMb(int bytes) => (bytes / (1024 * 1024)).toStringAsFixed(1);

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
          ],
        ),
      ),
    );
  }
}
