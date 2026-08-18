import 'dart:async';
import 'dart:convert';

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
        // 웹뷰 안에서 받은 스트림 조각(_downloadChunkViaWebView가 기다린다).
        if (msg.message.startsWith('chunk:')) {
          final probe = _chunkProbe;
          if (probe != null && !probe.isCompleted) {
            probe.complete(msg.message.substring('chunk:'.length));
          }
          return;
        }
        // 웹뷰 세션으로 해석한 player 응답(_resolveViaWebView가 기다린다).
        if (msg.message.startsWith('player:')) {
          final probe = _playerProbe;
          if (probe != null && !probe.isCompleted) {
            probe.complete(msg.message.substring('player:'.length));
          }
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
          // player 응답 가로채기를 가장 먼저 심는다. 사용자가 영상을 여는
          // 순간의 응답을 잡아야 하기 때문이다(§2.3.3).
          await _injectPlayerCapture();
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

  /// 저장이 진행 중이면 그 취소 토큰, 아니면 null.
  ///
  /// 진행 팝업은 모달이라 평소에는 저장 요청이 겹칠 수 없지만, "취소"를 누르면
  /// 팝업은 즉시 닫히는 반면 뒷정리(중간에 끊지 못하는 네트워크 대기 + `.part`
  /// 삭제)는 몇 초 더 걸린다. 그 틈에 다시 저장을 누르면 같은 파일에 두 다운로드가
  /// 붙어 `.part` 삭제와 rename이 서로를 덮어쓴다. 그래서 뒷정리가 끝날 때까지
  /// 재진입을 막고, 왜 지금 안 되는지 팝업으로 알려 준다.
  DownloadCancelToken? _activeDownload;

  Future<void> _startDownload(String videoId) async {
    final active = _activeDownload;
    if (active != null) {
      _btLog('save audio: 진행 중이라 재진입 차단 '
          '(cancelling=${active.isCancelled}) videoId=$videoId');
      await _showDownloadBusyNotice(cancelling: active.isCancelled);
      return;
    }
    final cancelToken = DownloadCancelToken();
    _activeDownload = cancelToken;
    try {
      await _runDownload(videoId, cancelToken);
    } finally {
      _activeDownload = null;
    }
  }

  /// 저장이 이미 돌고 있을 때의 안내. [cancelling]이면 취소 뒷정리 중이라
  /// 잠시 후 다시 시도하면 된다는 뜻이다.
  Future<void> _showDownloadBusyNotice({required bool cancelling}) async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(cancelling ? '저장 취소 정리 중' : '저장 진행 중'),
        content: Text(cancelling
            ? '이전 저장을 취소하고 정리하는 중입니다.\n잠시 후 다시 시도해 주세요.'
            : '이미 다른 오디오를 저장하고 있습니다.\n완료된 뒤에 다시 시도해 주세요.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('확인'),
          ),
        ],
      ),
    );
  }

  /// 유튜브 페이지 **자신의** player 응답을 가로채 저장해 둔다.
  ///
  /// 왜 필요한가: 유튜브는 PO token(`pot`) 없는 스트림 URL에 **첫 1MB만** 주고
  /// 그 뒤 range 요청은 전부 403으로 막는다(실측 2026-08-18: `bytes=0-1048575`
  /// 206 → `bytes=1048576-…` 403). 앱이 InnerTube를 직접 불러 만든 URL에는 그
  /// 토큰이 없다. 반면 **페이지가 재생을 위해 스스로 부른 player 응답**의 URL은
  /// 토큰을 달고 나오므로 끝까지 받을 수 있다.
  ///
  /// 그래서 fetch/XHR을 감싸 `/youtubei/v1/player` 응답을 videoId별로 모아 둔다.
  /// 사용자가 영상을 보다가 "오디오로 저장"을 누르는 흐름이라, 저장 시점엔 이미
  /// 그 영상의 응답이 잡혀 있다. 우리 자신이 보내는 요청(`_bt=1` 표시)은 담지
  /// 않는다 — 토큰 없는 응답으로 좋은 것을 덮어쓰면 안 된다.
  Future<void> _injectPlayerCapture() async {
    await _controller.runJavaScript(r'''
(function(){
  if (window.__btHooked) return;
  window.__btHooked = true;
  window.__btPlayer = {};
  function remember(txt){
    try {
      var j = JSON.parse(txt);
      var id = j && j.videoDetails && j.videoDetails.videoId;
      if (id && j.streamingData) {
        window.__btPlayer[id] = {t: Date.now(), json: j};
      }
    } catch(e){}
  }
  function isPlayer(u){
    u = u || '';
    return u.indexOf('/youtubei/v1/player') >= 0 && u.indexOf('_bt=1') < 0;
  }

  // ── 페이지가 보내는 player **요청 본문**에서 PO token을 훔쳐 온다 ──────
  // 스트림 URL이 1MB에서 잘리는 건 PO token이 없어서인데(§2.3.2.1), 그 토큰은
  // 페이지가 BotGuard로 만들어 자기 player 요청에 실어 보낸다. 응답만 보던
  // 기존 훅으로는 못 얻는다. 토큰과 그것에 묶인 visitorData를 함께 챙겨 두면
  // **우리가 만드는 요청에도 그대로 실어** 제한 없는 URL을 받을 수 있다.
  // 토큰은 세션(visitorData)에 묶여 있고 영상과 무관하다. 한 번 얻으면 다른
  // 영상 저장에도 그대로 쓸 수 있으므로, 페이지가 새로 로드돼도 잃지 않게
  // 저장해 둔다.
  window.__btAuth = null;
  try {
    var saved = localStorage.getItem('__btAuth');
    if (saved) {
      var pa = JSON.parse(saved);
      // 너무 오래된 토큰은 버린다(유튜브가 수 시간 단위로 무효화한다).
      if (pa && pa.poToken && (Date.now() - (pa.t || 0)) < 6*60*60*1000) {
        window.__btAuth = pa;
      }
    }
  } catch(e){}
  function saveAuth(a){
    window.__btAuth = a;
    try { localStorage.setItem('__btAuth', JSON.stringify(a)); } catch(e){}
  }
  function rememberAuth(body){
    try {
      if (!body || typeof body !== 'string') return;
      var j = JSON.parse(body);
      var pot = null;
      try { pot = j.serviceIntegrityDimensions.poToken; } catch(e){}
      var vd = null;
      try { vd = j.context.client.visitorData; } catch(e){}
      if (pot) {
        saveAuth({poToken: pot, visitorData: vd, t: Date.now(), src: 'req'});
      }
    } catch(e){}
  }

  // ── 플레이어가 실제로 재생에 쓰는 미디어 URL을 잡아 둔다 ──────────────
  // 이게 가장 확실한 소스다. 플레이어가 스트리밍 중인 URL이므로 서명·n·PO
  // token이 전부 유효하게 붙어 있다. player 응답을 뜯는 방식(서명이 걸려 있으면
  // 못 쓴다)과 달리 "이미 되고 있는 것"을 그대로 물려받는 셈이다.
  window.__btMedia = {};
  function currentVid(){
    try {
      var m = location.href.match(/[?&]v=([\w-]{6,})/);
      return m ? m[1] : null;
    } catch(e){ return null; }
  }
  function rememberMedia(u){
    try {
      if (!u || u.indexOf('googlevideo.com') < 0 ||
          u.indexOf('videoplayback') < 0) return;
      var qi = u.indexOf('?');
      if (qi < 0) return;
      var q = u.slice(qi + 1);
      var p = {};
      var parts = q.split('&');
      for (var i = 0; i < parts.length; i++) {
        var eq = parts[i].indexOf('=');
        if (eq > 0) p[parts[i].slice(0, eq)] = parts[i].slice(eq + 1);
      }
      if (!p.itag) return;
      // 요청마다 달라지는 파라미터는 떼어 낸다(우리가 range를 직접 붙인다).
      var drop = {range:1, rn:1, rbuf:1, ump:1, srfvp:1, sq:1, alr:1};
      var kept = [];
      for (var k = 0; k < parts.length; k++) {
        var key = parts[k].split('=')[0];
        if (!drop[key]) kept.push(parts[k]);
      }
      // 피드에서 인라인 재생하면 주소에 v= 가 없다. 그때는 '_last'에 담아 두고,
      // 해석 시 기대 크기(clen)가 일치할 때만 쓴다(다른 영상 오디오를 저장하는
      // 사고를 막는다).
      var vid = currentVid() || '_last';
      if (!window.__btMedia[vid]) window.__btMedia[vid] = {};
      window.__btMedia[vid][p.itag] = {
        url: u.slice(0, qi) + '?' + kept.join('&'),
        clen: parseInt(p.clen || '0', 10) || 0,
        dur: parseFloat(p.dur || '0') || 0,
        mime: decodeURIComponent(p.mime || '').replace('%2F', '/'),
        // 진단용: 어떤 파라미터가 실려 있었는지(pot/ump/sabr 유무가 핵심).
        keys: Object.keys(p).join(','),
        // 서명이 덮는 파라미터 목록. 여기에 range가 있으면 URL은 그 range
        // 전용이라 다른 구간을 요청하면 403이 난다.
        sp: decodeURIComponent(p.sparams || ''),
        // 플레이어가 원래 요청했던 range. URL 서명이 range까지 덮는지
        // 판단하는 근거가 된다.
        orig: p.range || ''
      };
      // 미디어 URL에 PO token이 붙어 있으면 그것을 우리 요청에도 재사용한다.
      if (p.pot && !window.__btAuth) {
        saveAuth({poToken: decodeURIComponent(p.pot), visitorData: null,
                  t: Date.now(), src: 'media-url'});
      }
    } catch(e){}
  }
  var of = window.fetch;
  if (of) {
    window.fetch = function(input, init){
      var u = (typeof input === 'string') ? input : ((input && input.url) || '');
      var p = of.apply(this, arguments);
      rememberMedia(u);
      if (isPlayer(u)) {
        try {
          var body = (init && init.body) ||
              (input && typeof input !== 'string' && input.body) || null;
          if (typeof body === 'string') rememberAuth(body);
        } catch(e){}
      }
      if (isPlayer(u)) {
        try {
          p.then(function(r){
            try { r.clone().text().then(remember); } catch(e){}
          });
        } catch(e){}
      }
      return p;
    };
  }
  var oo = XMLHttpRequest.prototype.open;
  var os = XMLHttpRequest.prototype.send;
  XMLHttpRequest.prototype.open = function(m, u){
    this.__btUrl = u;
    rememberMedia(u);
    return oo.apply(this, arguments);
  };
  XMLHttpRequest.prototype.send = function(body){
    var self = this;
    try { if (isPlayer(this.__btUrl)) rememberAuth(body); } catch(e){}
    try {
      this.addEventListener('load', function(){
        try { if (isPlayer(self.__btUrl)) remember(self.responseText); } catch(e){}
      });
    } catch(e){}
    return os.apply(this, arguments);
  };

  // 페이지가 이미 들고 있는 초기 재생 응답도 같은 창고에 넣는다.
  // watch 페이지는 이걸 전역으로 깔아 두므로, fetch/XHR을 못 잡아도(워커·서비스
  // 워커를 거치는 경우 등) 여기서 건질 수 있다. SPA로 영상을 옮겨 다니면 값이
  // 바뀌므로 주기적으로 다시 본다.
  // 요청 기록 버퍼를 넉넉히. 유튜브는 요청이 많아 기본값(250)이면 넘쳐서
  // 오래된 항목이 버려진다.
  try { performance.setResourceTimingBufferSize(1000); } catch(e){}

  function sweep(){
    // ★ Resource Timing에는 **페이지가 실제로 낸 모든 요청의 URL**이 남는다.
    // fetch/XHR을 감싸는 훅은 워커에서 나가는 요청이나 미디어 엔진이 내는
    // 요청을 못 잡는데(실측: video=blob 인데도 media=X), 이 목록에는 남는다.
    try {
      var es = performance.getEntriesByType('resource');
      for (var i = es.length - 1; i >= 0; i--) {
        var n = es[i].name || '';
        if (n.indexOf('videoplayback') >= 0) rememberMedia(n);
        // 미디어 URL이 아니어도 pot= 가 실린 요청이 있으면 토큰만 챙긴다.
        // 이 토큰은 로그인과 무관하게 페이지의 BotGuard가 만든 것이라,
        // 우리가 만드는 요청에 그대로 붙이면 1MB 제한이 풀린다(§2.3.2.1).
        if (!window.__btAuth && n.indexOf('pot=') >= 0 &&
            n.indexOf('googlevideo.com') >= 0) {
          try {
            var pm = n.match(/[?&]pot=([^&]+)/);
            if (pm) {
              saveAuth({poToken: decodeURIComponent(pm[1]),
                        visitorData: null, t: Date.now(), src: 'rt'});
            }
          } catch(e2){}
        }
      }
    } catch(e){}
    try {
      var r = window.ytInitialPlayerResponse;
      if (r && r.videoDetails && r.streamingData) {
        var id = r.videoDetails.videoId;
        if (id && !window.__btPlayer[id]) {
          window.__btPlayer[id] = {t: Date.now(), json: r};
        }
      }
    } catch(e){}
    // MSE 대신 <video src>로 바로 재생하는 경우(iOS에서 흔하다) fetch/XHR 훅에
    // 안 걸리므로 엘리먼트에서 직접 줍는다.
    try {
      var vs = document.getElementsByTagName('video');
      for (var i = 0; i < vs.length; i++) {
        rememberMedia(vs[i].currentSrc || vs[i].src || '');
      }
    } catch(e){}
  }
  sweep();
  setInterval(sweep, 2000);
})();
''');
  }

  /// 웹뷰가 보내 줄 player 응답을 기다리는 자리. 동시에 한 건만 돈다.
  Completer<String>? _playerProbe;

  /// 웹뷰가 보내 줄 스트림 조각을 기다리는 자리. 조각은 한 번에 하나씩 받는다
  /// (앞 조각이 도착해야 다음을 요청한다 — 메모리와 채널 부하를 묶어 둔다).
  Completer<String>? _chunkProbe;

  /// 봇 확인 우회 2단계: **다운로드 자체를 웹뷰 안에서** 한다.
  /// [url]의 [from]~[to] 바이트를 웹뷰 세션으로 받아 돌려준다. 실패하면 null.
  ///
  /// 앱이 보내는 HTTP 요청은 URL이 무엇이든 403인 기기가 있다(유튜브가 그
  /// 기기·IP를 의심하는 상태). 웹뷰는 이미 통과한 세션이므로 그 안에서 fetch
  /// 하면 받아진다 — googlevideo가 m.youtube.com 출처에 CORS를 열어 두고
  /// `Range` 헤더도 허용한다(실측 2026-08-18).
  ///
  /// JS 채널은 문자열만 전달하므로 base64로 싣는다(1MB → 약 1.33MB 문자열).
  Future<List<int>?> _downloadChunkViaWebView(Uri url, int from, int to) async {
    if (!mounted) return null;
    final completer = Completer<String>();
    _chunkProbe = completer;
    try {
      await _controller.runJavaScript(_chunkJs(url, from, to));
      final raw = await completer.future.timeout(const Duration(seconds: 60));
      final data = jsonDecode(raw) as Map<String, dynamic>;
      if (data['ok'] != true) {
        _btLog('webview chunk 실패 from=$from: '
            'status=${data['status']} err=${data['err']}');
        return null;
      }
      final bytes = base64Decode(data['b64'] as String);
      _btLog('webview chunk ok from=$from len=${bytes.length}');
      return bytes;
    } catch (e) {
      _btLog('webview chunk 오류 from=$from: $e');
      return null;
    } finally {
      _chunkProbe = null;
    }
  }

  /// 위 우회에 주입하는 스크립트. 결과는 JS 채널로 `chunk:<json>` 한 줄.
  String _chunkJs(Uri url, int from, int to) => '''
(function(){
  function post(o){
    try { $_jsChannelName.postMessage('chunk:' + JSON.stringify(o)); } catch(e){}
  }
  fetch(${jsonEncode(url.toString())}, {
    credentials: 'include',
    headers: {'Range': 'bytes=$from-$to'}
  }).then(function(r){
    if (r.status !== 200 && r.status !== 206) { post({ok:false, status:r.status}); return null; }
    return r.arrayBuffer();
  }).then(function(buf){
    if (!buf) return;
    // 큰 배열을 한 번에 String.fromCharCode에 넘기면 스택이 터진다 → 32KB씩.
    var b = new Uint8Array(buf), s = '', CH = 0x8000;
    for (var i = 0; i < b.length; i += CH) {
      s += String.fromCharCode.apply(null, b.subarray(i, i + CH));
    }
    post({ok:true, n:b.length, b64:btoa(s)});
  }).catch(function(e){ post({ok:false, err:String(e)}); });
})();
''';

  /// 봇 확인 우회: **웹뷰 세션 안에서** InnerTube player를 직접 호출해 오디오
  /// 스트림 URL을 얻는다. 실패하면 null.
  ///
  /// 앱이 Dart에서 보내는 요청은 새 세션이라 봇 확인에 걸리지만, 이 웹뷰는
  /// 사용자가 실제로 유튜브를 보던 세션이라 이미 확인을 통과해 있다. 같은
  /// 출처(youtube.com)에서 `credentials:'include'`로 부르므로 쿠키와
  /// visitorData가 그대로 실린다 — 앱이 쿠키를 직접 꺼내 다룰 필요가 없다.
  ///
  /// 컨텍스트는 ANDROID → IOS → 페이지 기본 순으로 시도한다. 앞의 둘은 URL이
  /// 서명 암호화되지 않아 그대로 받을 수 있고(디사이퍼 불필요), 페이지 기본
  /// (MWEB)은 `signatureCipher`만 오는 경우가 많아 마지막이다 — 그래서 `url`
  /// 필드가 있는 포맷만 고른다.
  Future<ResolvedAudioStream?> _resolveViaWebView(
    String videoId, {
    int expectSize = 0,
  }) async {
    if (!mounted) return null;
    _btLog('webview resolve: 시작 videoId=$videoId');
    final completer = Completer<String>();
    _playerProbe = completer;
    try {
      await _controller.runJavaScript(_playerProbeJs(videoId, expectSize));
      final raw = await completer.future.timeout(const Duration(seconds: 25));
      final data = jsonDecode(raw) as Map<String, dynamic>;
      if (data['ok'] != true) {
        _btLog('webview resolve 실패: ${data['reason']} [${data['diag']}]');
        return null;
      }
      final url = data['url'] as String?;
      if (url == null || url.isEmpty) return null;
      _btLog('webview resolve 성공: via=${data['via']} '
          'status=${data['status']} size=${data['size']} [${data['diag']}]');
      final seconds = (data['seconds'] as num?)?.toInt() ?? 0;
      final title = (data['title'] as String?) ?? '';
      final author = (data['author'] as String?) ?? '';
      return ResolvedAudioStream(
        url: Uri.parse(url),
        sizeBytes: (data['size'] as num?)?.toInt() ?? 0,
        mimeType: (data['mime'] as String?) ?? '',
        via: (data['via'] as String?) ?? 'webview',
        title: title.isEmpty ? null : title,
        author: author.isEmpty ? null : author,
        duration: seconds > 0 ? Duration(seconds: seconds) : null,
      );
    } catch (e) {
      _btLog('webview resolve 오류: $e');
      return null;
    } finally {
      _playerProbe = null;
    }
  }

  /// 위 우회에 주입하는 스크립트. 결과는 JS 채널로 `player:<json>` 한 줄.
  String _playerProbeJs(String videoId, int expectSize) => '''
(function(){
  function post(o){
    try { $_jsChannelName.postMessage('player:' + JSON.stringify(o)); } catch(e){}
  }
  function cfg(k){
    try { if (window.ytcfg && ytcfg.get) return ytcfg.get(k); } catch(e){}
    try { if (window.ytcfg && ytcfg.data_) return ytcfg.data_[k]; } catch(e){}
    return null;
  }
  var VIDEO = ${jsonEncode(videoId)};
  var EXPECT = $expectSize; // 매니페스트가 알려 준 기대 크기(0이면 모름)
  var ctx = cfg('INNERTUBE_CONTEXT') || {};
  var pageClient = ctx.client || {};
  var auth = window.__btAuth || null;
  // 페이지에서 훔친 토큰이 있으면 그것에 묶인 visitorData를 함께 써야 한다.
  var visitor = (auth && auth.visitorData) ||
      pageClient.visitorData || cfg('VISITOR_DATA') || '';
  var key = cfg('INNERTUBE_API_KEY') || '';
  var gl = pageClient.gl || 'KR';

  // 왜 실패하는지 로그에 남기기 위한 진단 수집기.
  var diag = {pot: auth ? 'O' : 'X', media: 'X', cap: 'X', ipr: 'X', html: 'X'};
  function diagText(){
    var v = [];
    for (var k in diag) v.push(k + '=' + diag[k]);
    return v.join(' ');
  }
  // 페이지가 어떤 방식으로 재생 중인지도 함께 본다(blob=MSE, https=직접재생).
  try {
    var vel = document.getElementsByTagName('video')[0];
    diag.video = vel ? (vel.currentSrc || vel.src || '').slice(0, 12) : 'none';
  } catch(e){ diag.video = 'err'; }
  // hl은 한국어로 고정한다(자동 더빙 영상의 언어 오선택 방지, AGENTS.md 2.4).
  var attempts = [
    // ANDROID_VR가 첫 번째다. 실측(2026-08-18)으로 **PO token 없이도 전체
    // 다운로드가 되는 유일한 클라이언트**다(다른 클라이언트 URL은 전부 첫 1MB
    // 이후 403). 다만 영상에 따라 LOGIN_REQUIRED가 나는데, 이 요청은 웹뷰
    // 세션에서 나가므로 사용자가 유튜브에 로그인해 두면 그 쿠키가 그대로 실려
    // 통과한다 — 앱이 쿠키를 직접 다루지 않고도 로그인 효과를 얻는 지점이다.
    {n:'ANDROID_VR', id:'28', v:'1.62.27', c:{clientName:'ANDROID_VR',
      clientVersion:'1.62.27', deviceMake:'Oculus', deviceModel:'Quest 3',
      androidSdkVersion:32, osName:'Android', osVersion:'12',
      hl:'ko', gl:gl, visitorData:visitor}},
    {n:'ANDROID', id:'3', v:'20.10.38', c:{clientName:'ANDROID',
      clientVersion:'20.10.38', androidSdkVersion:30, hl:'ko', gl:gl,
      visitorData:visitor}},
    {n:'IOS', id:'5', v:'20.10.4', c:{clientName:'IOS',
      clientVersion:'20.10.4', deviceMake:'Apple', deviceModel:'iPhone16,2',
      hl:'ko', gl:gl, visitorData:visitor}},
    {n:'PAGE', id:String(cfg('INNERTUBE_CONTEXT_CLIENT_NAME') || 2),
      v:pageClient.clientVersion || '', c:pageClient}
  ];
  // 오디오 포맷이 몇 개인지/평문 URL인지 암호화(signatureCipher)인지 센다.
  // "왜 이 경로가 못 쓰였나"를 로그에서 바로 알기 위한 것.
  function countAudio(j){
    try {
      var fs = ((j.streamingData || {}).adaptiveFormats || []);
      var au = 0, plain = 0, ciph = 0;
      for (var i = 0; i < fs.length; i++) {
        var m = fs[i].mimeType || '';
        if (m.indexOf('audio/mp4') !== 0) continue;
        au++;
        if (fs[i].url) plain++; else ciph++;
      }
      var hls = (j.streamingData || {}).hlsManifestUrl ? '+hls' : '';
      return au + '개(평문' + plain + '/암호' + ciph + ')' + hls;
    } catch(e){ return 'err'; }
  }

  function pick(j){
    var sd = j && j.streamingData;
    if (!sd) return null;
    // url이 있는(=서명 암호화되지 않은) mp4 오디오만. iOS AVPlayer는 webm/opus를
    // 재생하지 못한다(AGENTS.md 2.2).
    var f = (sd.adaptiveFormats || []).filter(function(x){
      return x && x.url && x.mimeType && x.mimeType.indexOf('audio/mp4') === 0;
    });
    if (!f.length) return null;
    var def = f.filter(function(x){
      return !x.audioTrack || x.audioTrack.audioIsDefault;
    });
    var pool = def.length ? def : f;
    pool.sort(function(a,b){ return (b.bitrate||0) - (a.bitrate||0); });
    return pool[0];
  }
  // ⓪ 플레이어가 지금 재생에 쓰고 있는 미디어 URL이 잡혀 있으면 그것이 정답이다.
  //    서명·n·PO token이 이미 유효하게 붙어 있어 range 제한에 걸리지 않는다.
  //    오디오 전용 itag 우선순위: 140(m4a 128k) → 141(256k) → 139(48k).
  try {
    var store = window.__btMedia || {};
    var med = store[VIDEO];
    // 피드에서 인라인 재생하면 주소에 v= 가 없어 '_last'에 담긴다. 그 경우
    // **기대 크기(clen)가 정확히 일치할 때만** 쓴다 — 다른 영상의 오디오를
    // 저장하는 사고를 막기 위한 유일한 확인 수단이다.
    if (!med && EXPECT > 0 && store._last) {
      var cand = {};
      for (var t in store._last) {
        if (store._last[t] && store._last[t].clen === EXPECT) cand[t] = store._last[t];
      }
      if (Object.keys(cand).length) { med = cand; diag.medsrc = 'last'; }
    }
    if (med) {
      diag.media = Object.keys(med).join('/') || 'empty';
      var order = ['140', '141', '139'];
      var chosen = null, chosenTag = null;
      for (var oi = 0; oi < order.length; oi++) {
        if (med[order[oi]] && med[order[oi]].url) {
          chosen = med[order[oi]]; chosenTag = order[oi]; break;
        }
      }
      // 목록에 없는 오디오 itag라도 mime이 audio면 받아들인다.
      if (!chosen) {
        for (var tag in med) {
          if (med[tag] && med[tag].url &&
              (med[tag].mime || '').indexOf('audio') === 0) {
            chosen = med[tag]; chosenTag = tag; break;
          }
        }
      }
      if (chosen) {
        diag.mkeys = chosen.keys || '?';
        diag.morig = chosen.orig || '-';
        diag.msp = chosen.sp || '-';
        post({
          ok: true, via: 'MEDIA-' + chosenTag, status: 'OK', diag: diagText(),
          url: chosen.url,
          size: chosen.clen || 0,
          mime: chosen.mime || 'audio/mp4',
          title: '', author: '',
          seconds: Math.round(chosen.dur || 0)
        });
        return;
      }
    }
  } catch(e){}

  // ① 페이지가 스스로 받아 둔 응답이 있으면 그것을 최우선으로 쓴다.
  //    이 URL에만 PO token이 붙어 있어 **끝까지** 받을 수 있다.
  try {
    var cached = (window.__btPlayer || {})[VIDEO];
    // 가로채기가 놓쳤어도 지금 페이지의 초기 응답이 그 영상이면 그것을 쓴다.
    if (!cached) {
      var ipr = window.ytInitialPlayerResponse;
      if (ipr && ipr.streamingData && ipr.videoDetails &&
          ipr.videoDetails.videoId === VIDEO) {
        cached = {t: Date.now(), json: ipr};
      }
    }
    if (cached && (Date.now() - cached.t) < 30*60*1000) {
      diag.cap = countAudio(cached.json);
      var b = pick(cached.json);
      if (b) {
        var cd = cached.json.videoDetails || {};
        post({
          ok: true, via: 'PAGE-CAPTURED', diag: diagText(),
          status: ((cached.json.playabilityStatus || {}).status || ''),
          url: b.url,
          size: parseInt(b.contentLength || '0', 10) || 0,
          mime: b.mimeType,
          title: cd.title || '', author: cd.author || '',
          seconds: parseInt(cd.lengthSeconds || '0', 10) || 0
        });
        return;
      }
    }
  } catch(e){}

  // ② 그 영상의 watch 페이지 HTML을 **웹뷰 세션으로** 받아 초기 재생 응답을
  //    꺼낸다. 사용자가 피드에서 바로 저장하면 ①이 비어 있는데, 이 경로는 그때도
  //    "페이지가 스스로 만든" 응답을 얻는다(쿠키·visitorData가 그대로 실린다).
  function fromWatchPage(next){
    fetch('/watch?v=' + VIDEO, {credentials:'include'})
      .then(function(r){ return r.text(); })
      .then(function(html){
        var key = 'ytInitialPlayerResponse';
        var i = html.indexOf(key);
        if (i < 0) { next(); return; }
        var s = html.indexOf('{', i);
        if (s < 0) { next(); return; }
        // 중괄호 균형으로 JSON 끝을 찾는다(문자열/이스케이프 고려).
        var d = 0, inStr = false, esc = false, end = -1;
        for (var k = s; k < html.length; k++) {
          var ch = html.charAt(k);
          if (esc) { esc = false; continue; }
          if (ch === '\\\\') { esc = true; continue; }
          if (ch === '"') { inStr = !inStr; continue; }
          if (inStr) continue;
          if (ch === '{') d++;
          else if (ch === '}') { d--; if (d === 0) { end = k + 1; break; } }
        }
        if (end < 0) { next(); return; }
        var j = JSON.parse(html.slice(s, end));
        diag.html = countAudio(j);
        var b = pick(j);
        if (!b) { next(); return; }
        var vd = j.videoDetails || {};
        post({
          ok: true, via: 'WATCH-HTML', diag: diagText(),
          status: ((j.playabilityStatus || {}).status || ''),
          url: b.url,
          size: parseInt(b.contentLength || '0', 10) || 0,
          mime: b.mimeType,
          title: vd.title || '', author: vd.author || '',
          seconds: parseInt(vd.lengthSeconds || '0', 10) || 0
        });
      })
      .catch(function(){ next(); });
  }

  function tryAt(i){
    if (i >= attempts.length) {
      post({ok:false, reason:'no-audio', diag:diagText()});
      return;
    }
    var a = attempts[i];
    // _bt=1: 이 요청은 가로채기 대상에서 빼라는 표시(토큰 없는 응답으로
    // 페이지가 받아 둔 좋은 응답을 덮어쓰지 않게 한다).
    var url = '/youtubei/v1/player?prettyPrint=false&_bt=1' +
        (key ? ('&key=' + key) : '');
    fetch(url, {
      method: 'POST',
      credentials: 'include',
      headers: {
        'Content-Type': 'application/json',
        'X-Goog-Visitor-Id': visitor,
        'X-YouTube-Client-Name': a.id,
        'X-YouTube-Client-Version': a.v
      },
      body: JSON.stringify({
        context: {client: a.c},
        videoId: VIDEO,
        contentCheckOk: true,
        racyCheckOk: true,
        // 훔쳐 온 PO token을 그대로 실어 보낸다. 이게 있으면 유튜브가
        // 1MB 제한 없는 URL을 내준다(§2.3.2.1).
        serviceIntegrityDimensions: auth ? {poToken: auth.poToken} : undefined
      })
    }).then(function(r){ return r.json(); }).then(function(j){
      diag['it_' + a.n] = countAudio(j);
      var best = pick(j);
      if (!best) { tryAt(i + 1); return; }
      // videoDetails도 같이 보낸다. watch 페이지 조회가 rate limit에 걸리면
      // 앱이 제목/저자/길이를 여기서 메운다.
      var d = j.videoDetails || {};
      // 페이지에서 확보한 PO token을 URL에도 붙인다. 응답의 스트림 URL에
      // 토큰이 없으면 첫 1MB 이후가 막히는데(§2.3.2.1), 같은 세션에서 나온
      // 토큰이므로 그대로 붙여 쓸 수 있다.
      var finalUrl = best.url;
      if (auth && auth.poToken && finalUrl.indexOf('pot=') < 0) {
        finalUrl += (finalUrl.indexOf('?') < 0 ? '?' : '&') +
            'pot=' + encodeURIComponent(auth.poToken);
        diag.potadd = 'O';
      }
      post({
        ok: true,
        via: a.n,
        diag: diagText(),
        status: ((j.playabilityStatus || {}).status || ''),
        url: finalUrl,
        size: parseInt(best.contentLength || '0', 10) || 0,
        mime: best.mimeType,
        title: d.title || '',
        author: d.author || '',
        seconds: parseInt(d.lengthSeconds || '0', 10) || 0
      });
    }).catch(function(){ tryAt(i + 1); });
  }
  // ①(가로채기·초기응답)이 위에서 이미 post 했으면 여기까지 오지 않는다.
  // ② watch 페이지 → 실패하면 ③ 우리가 직접 부르는 InnerTube 순.
  fromWatchPage(function(){ tryAt(0); });
})();
''';

  /// 저장이 사용자에게 설명 가능한 사유로 실패했을 때의 안내.
  /// [retryable]이면 시간이 지나면 될 수 있는 사유(봇 확인, 처리 중 등)다.
  Future<void> _showSaveFailedNotice(
    String message, {
    required bool retryable,
  }) async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(retryable ? '지금은 저장할 수 없습니다' : '저장할 수 없습니다'),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('확인'),
          ),
        ],
      ),
    );
  }

  Future<void> _runDownload(
    String videoId,
    DownloadCancelToken cancelToken,
  ) async {
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

    // 팝업은 취소·성공·실패 어느 경로로 닫히든 정확히 한 번만 닫아야 한다.
    // rootNavigator.pop()을 그냥 부르면 사용자가 이미 취소로 닫은 뒤에 성공/실패
    // 경로가 한 번 더 pop 해 웹뷰 화면까지 닫아 버린다. 그래서 팝업 자신의
    // route context를 기억해 두고 닫힘 여부를 플래그로 지킨다.
    BuildContext? dialogContext;
    var dialogClosed = false;
    void closeDialog() {
      if (dialogClosed) return;
      dialogClosed = true;
      final ctx = dialogContext;
      if (ctx != null && ctx.mounted) Navigator.of(ctx).pop();
    }

    if (mounted) {
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) {
          dialogContext = ctx;
          // 취소 버튼으로만 닫히게 한다(안드로이드 뒤로가기로 닫히면 다운로드는
          // 계속 도는데 팝업만 사라져 진행 상황을 볼 수 없다).
          return PopScope(
            canPop: false,
            child: AlertDialog(
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
              actions: [
                TextButton(
                  onPressed: () {
                    _btLog('save audio: 사용자 취소 videoId=$videoId');
                    cancelToken.cancel();
                    closeDialog();
                  },
                  child: const Text('취소'),
                ),
              ],
            ),
          );
        },
      );
    }

    try {
      final saved = await DownloadService.saveAudio(
        videoId,
        cancelToken: cancelToken,
        // 유튜브가 이 기기를 막았을 때의 우회 2단계(§2.3.3).
        resolveViaWebView: _resolveViaWebView,
        downloadChunkViaWebView: _downloadChunkViaWebView,
        // 첫 바이트가 오기 전 단계를 그대로 보여 준다. "준비 중"이 길어질 때
        // 어디서 걸렸는지(영상 정보 / 매니페스트 후보 / 다운로드 대기) 보인다.
        onStage: (stage) => label.value = stage,
        onBytes: (received, total) {
          progress.value = total > 0 ? received / total : null;
          label.value = total > 0
              ? '${_fmtMb(received)} / ${_fmtMb(total)} MB'
              : '${_fmtMb(received)} MB 받는 중...';
        },
      ).timeout(const Duration(minutes: 5));
      closeDialog();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('저장 완료: ${saved.title}')),
        );
      }
    } on DownloadCancelledException {
      // 실패가 아니라 사용자의 선택이므로 에러 안내를 띄우지 않는다.
      // (팝업은 취소를 누른 시점에 이미 닫혔다)
      _btLog('save audio cancelled videoId=$videoId');
      closeDialog();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('저장을 취소했습니다')),
        );
      }
    } on AudioUnavailableException catch (e) {
      // 봇 확인/로그인 요구, 처리 중(post-live), 비공개 등 "왜 안 되는지"를
      // 설명할 수 있는 사유. 스낵바는 웹뷰를 보다 놓치기 쉬워 팝업으로 알린다.
      _btLog('save audio unavailable: $e');
      closeDialog();
      await _showSaveFailedNotice('$e', retryable: e.retryable);
    } catch (e) {
      _btLog('save audio error: $e');
      closeDialog();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('저장 실패: $e'),
            duration: const Duration(seconds: 4),
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
