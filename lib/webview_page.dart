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
