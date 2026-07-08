import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';

import 'player_service.dart';

/// 곡 재생 화면. 공유 플레이어(btPlayer)의 현재 곡/진행 상태를 그대로 반영한다.
/// 별도 소스를 로드하지 않고 스트림만 구독하므로, 저장파일 단일 재생·전체재생·
/// 플레이리스트 자동 넘김 어느 경우에나 그대로 붙는다.
class PlayerScreen extends StatefulWidget {
  /// 탭한 곡의 메타데이터(선택). 재생 소스가 로드되기 전에도 제목/아트워크를
  /// 즉시 보여주기 위한 힌트. 로드가 끝나면 스트림 값으로 대체된다.
  final MediaItem? initialMedia;

  const PlayerScreen({super.key, this.initialMedia});

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  // 첨부 시안의 웜 골드 계열 강조색.
  static const Color _accent = Color(0xFFE4D7B0);
  static const Color _bg = Color(0xFF0C0C0C);
  static const List<double> _speeds = [1.0, 1.25, 1.5, 1.75, 2.0];

  MediaItem? _media;
  Duration _position = Duration.zero;
  Duration? _duration;
  bool _playing = false;
  bool _shuffle = false;
  LoopMode _loop = LoopMode.off;
  double _speed = 1.0;
  int _tab = 0; // 0 = Song, 1 = Lyrics

  // 원형 진행바를 드래그해 탐색하는 동안의 임시 위치(0~1). 놓으면 seek 후 null.
  double? _dragFraction;

  final List<StreamSubscription<dynamic>> _subs = [];

  @override
  void initState() {
    super.initState();
    final tag = btPlayer.sequenceState.currentSource?.tag;
    _media = widget.initialMedia ?? (tag is MediaItem ? tag : null);
    debugPrint('[BT] screen: PlayerScreen 진입 곡="${_media?.title}" '
        'playing=${btPlayer.playing}');
    _position = btPlayer.position;
    _duration = btPlayer.duration;
    _playing = btPlayer.playing;
    _shuffle = btPlayer.shuffleModeEnabled;
    _loop = btPlayer.loopMode;
    _speed = btPlayer.speed;

    _subs.add(btPlayer.positionStream.listen((p) {
      if (mounted && _dragFraction == null) setState(() => _position = p);
    }));
    _subs.add(btPlayer.durationStream.listen((d) {
      if (mounted) setState(() => _duration = d);
    }));
    _subs.add(btPlayer.playerStateStream.listen((s) {
      if (mounted) setState(() => _playing = s.playing);
    }));
    _subs.add(btPlayer.sequenceStateStream.listen((_) {
      final t = btPlayer.sequenceState.currentSource?.tag;
      if (mounted && t is MediaItem) setState(() => _media = t);
    }));
    _subs.add(btPlayer.shuffleModeEnabledStream.listen((v) {
      if (mounted) setState(() => _shuffle = v);
    }));
    _subs.add(btPlayer.loopModeStream.listen((v) {
      if (mounted) setState(() => _loop = v);
    }));
  }

  @override
  void dispose() {
    debugPrint('[BT] screen: PlayerScreen 이탈');
    for (final s in _subs) {
      s.cancel();
    }
    super.dispose();
  }

  double get _fraction {
    if (_dragFraction != null) return _dragFraction!;
    final d = _duration;
    if (d == null || d.inMilliseconds == 0) return 0;
    return (_position.inMilliseconds / d.inMilliseconds).clamp(0.0, 1.0);
  }

  Future<void> _togglePlay() async {
    debugPrint('[BT] player: ${_playing ? "일시정지" : "재생"} 버튼');
    if (_playing) {
      btPlayIntent = false;
      await btPlayer.pause();
    } else {
      btPlayIntent = true;
      await btPlayer.play();
    }
  }

  Future<void> _prev() async {
    debugPrint('[BT] player: 이전 버튼 pos=${btPlayer.position} '
        'hasPrev=${btPlayer.hasPrevious}');
    // 3초 이상 재생됐으면 현재 곡을 처음으로, 아니면 이전 곡으로.
    if (btPlayer.position > const Duration(seconds: 3) || !btPlayer.hasPrevious) {
      await btPlayer.seek(Duration.zero);
    } else {
      await btPlayer.seekToPrevious();
    }
  }

  Future<void> _next() async {
    debugPrint('[BT] player: 다음 버튼 hasNext=${btPlayer.hasNext}');
    if (btPlayer.hasNext) await btPlayer.seekToNext();
  }

  Future<void> _toggleShuffle() async {
    final on = !_shuffle;
    await btPlayer.setShuffleModeEnabled(on);
    if (on) await btPlayer.shuffle();
  }

  Future<void> _cycleRepeat() async {
    final next = switch (_loop) {
      LoopMode.off => LoopMode.all,
      LoopMode.all => LoopMode.one,
      LoopMode.one => LoopMode.off,
    };
    await btPlayer.setLoopMode(next);
  }

  Future<void> _cycleSpeed() async {
    final idx = _speeds.indexWhere((s) => (s - _speed).abs() < 0.01);
    final next = _speeds[(idx + 1) % _speeds.length];
    try {
      await btPlayer.setSpeed(next);
      if (mounted) setState(() => _speed = next);
    } catch (_) {}
  }

  String _fmtSpeed(double s) {
    var t = s.toStringAsFixed(2);
    if (t.contains('.')) {
      t = t.replaceAll(RegExp(r'0+$'), '').replaceAll(RegExp(r'\.$'), '');
    }
    return '$t×';
  }

  // 드래그 지점 → 진행률(0~1). 12시 방향을 0으로 시계방향 증가.
  double _fractionFromOffset(Offset local, double size) {
    final c = size / 2;
    var a = atan2(local.dy - c, local.dx - c) + pi / 2;
    if (a < 0) a += 2 * pi;
    return (a / (2 * pi)).clamp(0.0, 1.0);
  }

  Future<void> _seekToDrag() async {
    final d = _duration;
    final f = _dragFraction;
    if (d != null && f != null) {
      await btPlayer.seek(d * f);
    }
    if (mounted) setState(() => _dragFraction = null);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        foregroundColor: Colors.white,
        centerTitle: true,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new, size: 20),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        title: Text(
          _media?.title ?? 'BackTube',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: TextButton(
              onPressed: _cycleSpeed,
              child: Text(
                _fmtSpeed(_speed),
                style: const TextStyle(
                  color: _accent,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            const SizedBox(height: 4),
            _buildTabs(),
            Expanded(
              child: Center(
                child: _tab == 0 ? _buildArtwork(context) : _buildLyrics(),
              ),
            ),
            _buildTitleArtist(),
            const SizedBox(height: 28),
            _buildControls(),
            const SizedBox(height: 20),
          ],
        ),
      ),
    );
  }

  Widget _buildTabs() {
    Widget label(String text, int idx) {
      final selected = _tab == idx;
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => setState(() => _tab = idx),
        child: Text(
          text,
          style: TextStyle(
            fontSize: 16,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            color: selected ? Colors.white : Colors.white38,
          ),
        ),
      );
    }

    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        label('Song', 0),
        Container(
          width: 1,
          height: 14,
          margin: const EdgeInsets.symmetric(horizontal: 16),
          color: Colors.white24,
        ),
        label('Lyrics', 1),
      ],
    );
  }

  Widget _buildArtwork(BuildContext context) {
    final s = min(MediaQuery.of(context).size.width * 0.72, 300.0);
    final artDiameter = s - 44;
    return GestureDetector(
      onPanStart: (d) =>
          setState(() => _dragFraction = _fractionFromOffset(d.localPosition, s)),
      onPanUpdate: (d) =>
          setState(() => _dragFraction = _fractionFromOffset(d.localPosition, s)),
      onPanEnd: (_) => _seekToDrag(),
      onPanCancel: () => setState(() => _dragFraction = null),
      child: SizedBox(
        width: s,
        height: s,
        child: Stack(
          alignment: Alignment.center,
          children: [
            CustomPaint(
              size: Size.square(s),
              painter: _RingPainter(
                fraction: _fraction,
                track: Colors.white.withValues(alpha: 0.10),
                progress: _accent,
              ),
            ),
            ClipOval(
              child: SizedBox(
                width: artDiameter,
                height: artDiameter,
                child: _artworkImage(),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _artworkImage() {
    final fallback = Container(
      color: const Color(0xFF1C1C1C),
      alignment: Alignment.center,
      child: const Icon(Icons.music_note, size: 64, color: Colors.white24),
    );
    final uri = _media?.artUri;
    if (uri == null) return fallback;
    if (uri.scheme == 'file') {
      return Image.file(
        File(uri.toFilePath()),
        fit: BoxFit.cover,
        width: double.infinity,
        height: double.infinity,
        errorBuilder: (_, __, ___) => fallback,
      );
    }
    return Image.network(
      uri.toString(),
      fit: BoxFit.cover,
      width: double.infinity,
      height: double.infinity,
      errorBuilder: (_, __, ___) => fallback,
    );
  }

  Widget _buildLyrics() {
    return const Padding(
      padding: EdgeInsets.all(32),
      child: Center(
        child: Text(
          '가사를 지원하지 않아요',
          style: TextStyle(color: Colors.white38, fontSize: 15),
        ),
      ),
    );
  }

  Widget _buildTitleArtist() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Column(
        children: [
          Text(
            _media?.title ?? '재생 중인 곡 없음',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.bold,
              color: Colors.white,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            _media?.artist ?? '',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 14, color: Colors.white54),
          ),
        ],
      ),
    );
  }

  Widget _buildControls() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 28),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          IconButton(
            onPressed: _toggleShuffle,
            icon: Icon(
              Icons.shuffle,
              color: _shuffle ? _accent : Colors.white70,
              size: 24,
            ),
          ),
          IconButton(
            onPressed: _prev,
            icon: const Icon(Icons.skip_previous, color: Colors.white, size: 38),
          ),
          GestureDetector(
            onTap: _togglePlay,
            child: Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: _accent,
                boxShadow: [
                  BoxShadow(
                    color: _accent.withValues(alpha: 0.25),
                    blurRadius: 18,
                    spreadRadius: 1,
                  ),
                ],
              ),
              child: Icon(
                _playing ? Icons.pause : Icons.play_arrow,
                color: const Color(0xFF1A1A1A),
                size: 38,
              ),
            ),
          ),
          IconButton(
            onPressed: _next,
            icon: const Icon(Icons.skip_next, color: Colors.white, size: 38),
          ),
          IconButton(
            onPressed: _cycleRepeat,
            icon: Icon(
              _loop == LoopMode.one ? Icons.repeat_one : Icons.repeat,
              color: _loop == LoopMode.off ? Colors.white70 : _accent,
              size: 24,
            ),
          ),
        ],
      ),
    );
  }
}

/// 앨범아트 둘레의 원형 진행바. 12시에서 시작해 시계방향으로 채운다.
class _RingPainter extends CustomPainter {
  final double fraction;
  final Color track;
  final Color progress;

  _RingPainter({
    required this.fraction,
    required this.track,
    required this.progress,
  });

  @override
  void paint(Canvas canvas, Size size) {
    const stroke = 4.0;
    const dotRadius = 6.0;
    final center = size.center(Offset.zero);
    final radius = size.shortestSide / 2 - dotRadius - 2;

    final trackPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..color = track;
    canvas.drawCircle(center, radius, trackPaint);

    final sweep = 2 * pi * fraction.clamp(0.0, 1.0);
    const start = -pi / 2;
    final progPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round
      ..color = progress;
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      start,
      sweep,
      false,
      progPaint,
    );

    final angle = start + sweep;
    final dot = Offset(
      center.dx + radius * cos(angle),
      center.dy + radius * sin(angle),
    );
    canvas.drawCircle(dot, dotRadius, Paint()..color = progress);
  }

  @override
  bool shouldRepaint(covariant _RingPainter old) =>
      old.fraction != fraction ||
      old.progress != progress ||
      old.track != track;
}
