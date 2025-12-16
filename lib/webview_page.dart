import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'audio_player_page.dart';

class WebViewPage extends StatefulWidget {
  @override
  State<WebViewPage> createState() => _WebViewPageState();
}

class _WebViewPageState extends State<WebViewPage> with WidgetsBindingObserver {
  late final WebViewController _controller;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(NavigationDelegate(
        onPageFinished: (String url) {
          _injectAutoYesScript();
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
    if (state == AppLifecycleState.paused) {
      _handleBackgroundAudio();
    }
  }

  Future<void> _injectAutoYesScript() async {
    const script = r'''
      (function() {
        if (window._backtubeAutoYes) return;
        window._backtubeAutoYes = true;

        function clickButtonsIn(node) {
          try {
            // 고려: 모달 전체 텍스트를 보고 판단
            var text = (node.innerText || node.textContent || '') + '';
            if (text.indexOf('동영상') !== -1 && (text.indexOf('일시') !== -1 || text.indexOf('중지') !== -1 || text.indexOf('이어') !== -1)) {
              var btns = node.querySelectorAll('button, a, input');
              for (var i = 0; i < btns.length; i++) {
                var b = btns[i];
                var bt = (b.innerText || b.value || b.textContent || '').trim();
                if (bt === '예' || bt === '예]') { try { b.click(); } catch(e){}; return true; }
                if (bt.indexOf('예') === 0) { try { b.click(); } catch(e){}; return true; }
              }
              var any = node.querySelector('button, a, input[type=button], input[type=submit]');
              if (any) { try { any.click(); } catch(e){}; return true; }
            }
          } catch (e) {}
          return false;
        }

        // 초기 시도
        if (clickButtonsIn(document.body)) return;

        // 변화 관찰
        var obs = new MutationObserver(function(mutations) {
          for (var m = 0; m < mutations.length; m++) {
            var added = mutations[m].addedNodes || [];
            for (var i = 0; i < added.length; i++) {
              var n = added[i];
              if (n && n.nodeType === 1) {
                if (clickButtonsIn(n)) return;
              }
            }
          }
        });
        obs.observe(document.documentElement || document.body, { childList: true, subtree: true });

        // 기본 confirm 오버라이드로 메시지 기반 자동 수락
        try {
          var _origConfirm = window.confirm.bind(window);
          window.confirm = function(msg) {
            try {
              if (String(msg).indexOf('동영상') !== -1 && String(msg).indexOf('이어') !== -1) return true;
            } catch (e) {}
            return _origConfirm(msg);
          };
        } catch (e) {}
      })();
    ''';

    try {
      await _controller.runJavaScript(script);
    } catch (e) {
      // JS 실행 실패 시 무시
    }
  }

  // 백그라운드 진입 시, 팝업이 떠서 재생이 멈출 경우를 대비해
  // 즉시 팝업 클릭을 여러 번 시도한 뒤 재생 정보를 읽어옴
  Future<void> _handleBackgroundAudio() async {
    const clickScript = r'''
      (function(){
        function tryClick() {
          try {
            var all = document.querySelectorAll('div, dialog, section, article, form');
            for (var i = 0; i < all.length; i++) {
              var n = all[i];
              var text = (n.innerText || n.textContent || '') + '';
              if (text.indexOf('동영상') !== -1 && (text.indexOf('일시') !== -1 || text.indexOf('중지') !== -1 || text.indexOf('이어') !== -1)) {
                var btns = n.querySelectorAll('button, a, input');
                for (var j = 0; j < btns.length; j++) {
                  var b = btns[j];
                  var bt = (b.innerText || b.value || b.textContent || '').trim();
                  if (bt === '예' || bt.indexOf('예') === 0) { try { b.click(); } catch(e){}; return true; }
                }
                var any = n.querySelector('button, a, input[type=button], input[type=submit]');
                if (any) { try { any.click(); } catch(e){}; return true; }
              }
            }
            // 마지막 수단: 페이지 전체에서 '예' 문자 버튼 클릭
            var buttons = document.querySelectorAll('button, a, input');
            for (var k = 0; k < buttons.length; k++) {
              var bb = buttons[k];
              var tb = (bb.innerText || bb.value || bb.textContent || '').trim();
              if (tb === '예' || tb.indexOf('예') === 0) { try{ bb.click(); } catch(e){}; return true; }
            }
          } catch(e){}
          return false;
        }
        // 여러 번 시도 (setInterval으로 최대 8회)
        if (tryClick()) return true;
        var attempts = 0;
        var id = setInterval(function(){ attempts++; if(tryClick() || attempts>7) clearInterval(id); }, 300);
        return true;
      })();
    ''';

    try {
      // 우선 팝업 자동 클릭 시도
      await _controller.runJavaScript(clickScript);
    } catch (e) {}

    // 약간의 지연을 둔 뒤 재생 정보 추출
    await Future.delayed(Duration(milliseconds: 250));

    final videoId = await _controller.runJavaScriptReturningResult('''
      (function() {
        var url = window.location.href;
        var match = url.match(/v=([\w-]+)/);
        if (match) return match[1];
        // m.youtube의 경우 data-video-id 속성을 확인
        var el = document.querySelector('[data-video-id]');
        return el ? el.getAttribute('data-video-id') : null;
      })();
    ''');

    final position = await _controller.runJavaScriptReturningResult('''
      (function() {
        var v = document.querySelector('video');
        return v ? v.currentTime : 0;
      })();
    ''');

    final vid = videoId?.toString().replaceAll('"', '');
    final pos = double.tryParse(position?.toString() ?? '0') ?? 0;
    if (vid != null && vid.isNotEmpty && vid != 'null') {
      if (mounted) {
        Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => AudioPlayerPage(videoId: vid, position: pos),
        ));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('BackTube')),
      body: WebViewWidget(controller: _controller),
    );
  }
}
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'audio_player_page.dart';

class WebViewPage extends StatefulWidget {
  @override
  State<WebViewPage> createState() => _WebViewPageState();
}

class _WebViewPageState extends State<WebViewPage> with WidgetsBindingObserver {
  late final WebViewController _controller;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(NavigationDelegate(
        onPageFinished: (String url) {
          _injectAutoYesScript();
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
    if (state == AppLifecycleState.paused) {
      _handleBackgroundAudio();
    }
  }

  Future<void> _injectAutoYesScript() async {
    const script = r'''
      (function() {
        if (window._backtubeAutoYes) return;
        window._backtubeAutoYes = true;

        function clickYesIfFound(node) {
          try {
            var text = (node.innerText || node.textContent || '') + '';
            if (text.indexOf('동영상') !== -1 && (text.indexOf('일시') !== -1 || text.indexOf('중지') !== -1)) {
              // 버튼 텍스트가 '예'인 경우 클릭
              var btns = node.querySelectorAll('button, a, input');
              for (var i = 0; i < btns.length; i++) {
                var b = btns[i];
                var bt = (b.innerText || b.value || b.textContent || '').trim();
                if (bt === '예' || bt === '예]') { try { b.click(); } catch(e){}; return true; }
                if (bt.indexOf('예') === 0) { try { b.click(); } catch(e){}; return true; }
              }
              // fallback: 클릭 가능한 첫 요소
              var any = node.querySelector('button, a, input[type=button], input[type=submit]');
              if (any) { try { any.click(); } catch(e){}; return true; }
            }
          } catch (e) {}
          return false;
        }

        // 초기 탐색
        if (clickYesIfFound(document.body)) return;

        // DOM 변경 감시
        var obs = new MutationObserver(function(mutations) {
          for (var m = 0; m < mutations.length; m++) {
            var added = mutations[m].addedNodes || [];
            for (var i = 0; i < added.length; i++) {
              var n = added[i];
              if (n && n.nodeType === 1) {
                if (clickYesIfFound(n)) return;
              }
            }
          }
        });
        obs.observe(document.documentElement || document.body, { childList: true, subtree: true });

        // window.confirm 자동 수락 (메시지 매칭 시)
        try {
          var _origConfirm = window.confirm.bind(window);
          window.confirm = function(msg) {
            try {
              if (String(msg).indexOf('동영상') !== -1 && String(msg).indexOf('이어') !== -1) return true;
            } catch (e) {}
            return _origConfirm(msg);
          };
        } catch (e) {}
      })();
    ''';

    try {
      await _controller.runJavaScript(script);
    } catch (e) {
      // 무시: JS 실행 실패해도 앱이 깨지면 안됨
    }
  }

  Future<void> _handleBackgroundAudio() async {
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
    final vid = videoId?.toString().replaceAll('"', '');
    final pos = double.tryParse(position?.toString() ?? '0') ?? 0;
    if (vid != null && vid.isNotEmpty && vid != 'null') {
      Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => AudioPlayerPage(videoId: vid, position: pos),
      ));
    }
  }

  Future<String?> fetchAudioStreamUrl(String videoId, double position) async {
    final url = Uri.parse('https://your-server.com/api/youtube_audio?videoId=$videoId&position=$position');
    try {
      final response = await NetworkAssetBundle(url).load(url.toString());
      final audioUrl = String.fromCharCodes(response.buffer.asUint8List());
      return audioUrl;
    } catch (e) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('BackTube')),
      body: WebViewWidget(controller: _controller),
    );
  }
}
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'audio_player_page.dart';

class WebViewPage extends StatefulWidget {
  @override
  State<WebViewPage> createState() => _WebViewPageState();
}

class _WebViewPageState extends State<WebViewPage> with WidgetsBindingObserver {
  late final WebViewController _controller;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
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
    if (state == AppLifecycleState.paused) {
      _handleBackgroundAudio();
    }
  }

  Future<void> _handleBackgroundAudio() async {
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
      Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => AudioPlayerPage(videoId: vid, position: pos),
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('BackTube')),
      body: WebViewWidget(controller: _controller),
    );
  }
}
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'audio_player_page.dart';

class WebViewPage extends StatefulWidget {
  @override
  State<WebViewPage> createState() => _WebViewPageState();
}

class _WebViewPageState extends State<WebViewPage> with WidgetsBindingObserver {
  late final WebViewController _controller;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
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
    if (state == AppLifecycleState.paused) {
      _handleBackgroundAudio();
    }
  }

  Future<void> _handleBackgroundAudio() async {
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
      Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => AudioPlayerPage(videoId: vid, position: pos),
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('BackTube')),
      body: WebViewWidget(controller: _controller),
    );
  }
}
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'audio_player_page.dart';

class WebViewPage extends StatefulWidget {
  @override
  State<WebViewPage> createState() => _WebViewPageState();
}

class _WebViewPageState extends State<WebViewPage> with WidgetsBindingObserver {
  late final WebViewController _controller;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
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
    if (state == AppLifecycleState.paused) {
      _handleBackgroundAudio();
    }
  }

  Future<void> _handleBackgroundAudio() async {
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
      Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => AudioPlayerPage(videoId: vid, position: pos),
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('BackTube')),
      body: WebViewWidget(controller: _controller),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'audio_player_page.dart';

class WebViewPage extends StatefulWidget {
  @override
  State<WebViewPage> createState() => _WebViewPageState();
}

class _WebViewPageState extends State<WebViewPage> with WidgetsBindingObserver {
  late final WebViewController _controller;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
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
    if (state == AppLifecycleState.paused) {
      _handleBackgroundAudio();
    }
  }

  Future<void> _handleBackgroundAudio() async {
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
      Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => AudioPlayerPage(videoId: vid, position: pos),
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('BackTube')),
      body: WebViewWidget(controller: _controller),
    );
  }
}
      if (state == AppLifecycleState.paused) {
        _handleBackgroundAudio();
      }
    }

    Future<void> _handleBackgroundAudio() async {
      // 1. 유튜브 영상 ID와 현재 재생 위치 추출 (JS 실행)
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
      final vid = videoId?.toString().replaceAll('"', '');
      final pos = double.tryParse(position?.toString() ?? '0') ?? 0;
      if (vid != null && vid.isNotEmpty && vid != 'null') {
        // 2. 서버에서 오디오 스트림 URL 받아오기 (예시 API)
        final audioUrl = await fetchAudioStreamUrl(vid, pos);
        if (audioUrl != null && mounted) {
          Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => AudioPlayerPage(videoId: vid, position: pos),
          ));
        }
      }
    }

    Future<String?> fetchAudioStreamUrl(String videoId, double position) async {
      // 실제 서버 API 주소로 교체 필요
      final url = Uri.parse('https://your-server.com/api/youtube_audio?videoId=$videoId&position=$position');
      try {
        final response = await NetworkAssetBundle(url).load(url.toString());
        final audioUrl = String.fromCharCodes(response.buffer.asUint8List());
        return audioUrl;
      } catch (e) {
        return null;
      }
    }

    @override
    Widget build(BuildContext context) {
      return Scaffold(
        appBar: AppBar(title: Text('BackTube')),
        body: WebViewWidget(controller: _controller),
      );
    }
  }
