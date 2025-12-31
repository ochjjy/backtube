import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

class WebViewPage extends StatefulWidget {
  const WebViewPage({super.key});

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
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageFinished: (_) async {
            await _injectAutoYesScript();
          },
        ),
      )
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
    // WebView는 백그라운드에서 JS 실행이 제한될 수 있어, 가능한 범위에서만 시도.
    if (state == AppLifecycleState.paused) {
      _armBackgroundClickerBestEffort();
    } else if (state == AppLifecycleState.resumed) {
      _injectAutoYesScript();
    }
  }

  Future<void> _injectAutoYesScript() async {
    const script = r"""
(function() {
  function normalize(s) {
    return (s || '').replace(/\s+/g, ' ').trim();
  }

  function looksLikePauseDialog(root) {
    var text = normalize((root && root.innerText) || '');
    return text.indexOf('동영상') !== -1 && (text.indexOf('일시') !== -1 || text.indexOf('중지') !== -1) && text.indexOf('이어') !== -1;
  }

  function clickYesWithin(root) {
    if (!root) return false;

    var buttons = root.querySelectorAll('button, tp-yt-paper-button, yt-button-shape button');
    for (var i = 0; i < buttons.length; i++) {
      var b = buttons[i];
      var t = normalize(b.innerText);
      if (t === '예') {
        b.click();
        return true;
      }
    }

    if (looksLikePauseDialog(root)) {
      var any = root.querySelector('button');
      if (any) {
        any.click();
        return true;
      }
    }

    return false;
  }

  function tryClick() {
    var candidates = [];
    candidates.push(document.querySelector('tp-yt-paper-dialog'));
    candidates.push(document.querySelector('yt-confirm-dialog-renderer'));
    candidates.push(document.querySelector('ytd-popup-container'));
    candidates.push(document.body);

    for (var i = 0; i < candidates.length; i++) {
      var c = candidates[i];
      if (c && clickYesWithin(c)) return true;
    }
    return false;
  }

  tryClick();

  if (!window.__backtubePauseObs) {
    window.__backtubePauseObs = new MutationObserver(function() {
      tryClick();
    });
    window.__backtubePauseObs.observe(document.documentElement || document.body, { childList: true, subtree: true });
  }

  try {
    if (!window.__backtubeOrigConfirm) {
      window.__backtubeOrigConfirm = window.confirm.bind(window);
      window.confirm = function(msg) {
        try {
          var m = String(msg || '');
          if (m.indexOf('동영상') !== -1 && m.indexOf('이어') !== -1) return true;
        } catch (e) {}
        return window.__backtubeOrigConfirm(msg);
      };
    }
  } catch (e) {}
})();
""";

    try {
      await _controller.runJavaScript(script);
    } catch (_) {
      // ignore
    }
  }

  Future<void> _armBackgroundClickerBestEffort() async {
    const clicker = r"""
(function() {
  function normalize(s) { return (s || '').replace(/\s+/g, ' ').trim(); }
  function clickYes() {
    var buttons = document.querySelectorAll('button, tp-yt-paper-button, yt-button-shape button');
    for (var i = 0; i < buttons.length; i++) {
      var b = buttons[i];
      if (normalize(b.innerText) === '예') { b.click(); return true; }
    }
    return false;
  }
  if (window.__backtubeClickerTimer) return;
  var start = Date.now();
  window.__backtubeClickerTimer = setInterval(function() {
    clickYes();
    if (Date.now() - start > 120000) {
      clearInterval(window.__backtubeClickerTimer);
      window.__backtubeClickerTimer = null;
    }
  }, 1000);
})();
""";

    try {
      await _controller.runJavaScript(clicker);
    } catch (_) {
      // ignore
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('BackTube')),
      body: WebViewWidget(controller: _controller),
    );
  }
}
