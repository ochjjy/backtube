import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';

import 'live_service.dart';
import 'player_service.dart';

/// 메뉴에서 라이브를 시작한다. 웹뷰 없이 페이지를 헤드리스로 파싱해 오디오만
/// 물고 오므로, 해석이 끝나면 곧바로 재생 화면으로 들어간다.
Future<void> openLiveAudio(BuildContext context) async {
  // 공유 플레이어를 쓰기 전에 오디오 초기화 완료를 보장한다(AGENTS.md §2.6).
  if (!audioReady) {
    final busy = _BusyDialog()..show(context, '초기화 중...');
    try {
      await ensureAudioReady();
    } catch (_) {
    } finally {
      busy.close();
    }
  }
  if (!context.mounted) return;

  // 진행 팝업은 성공/실패/예외 어느 경로로 빠져나가도 반드시 닫아야 한다.
  // (한 번 남으면 사용자가 앱을 재시작하는 수밖에 없다)
  final busy = _BusyDialog()..show(context, '라이브 연결 중...');
  Object? error;
  try {
    // resolve의 각 HTTP 단계에 20초 타임아웃이 있지만, 전체로도 상한을 둔다.
    await LiveSession.instance.start().timeout(const Duration(seconds: 45));
  } catch (e) {
    error = e;
    debugPrint('[BT] live: 시작 실패 $e');
  } finally {
    busy.close();
  }

  if (!context.mounted) return;
  if (error != null) {
    final known = error is LiveUnavailableException;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(known ? '$error' : '라이브를 시작하지 못했습니다: $error'),
        duration: const Duration(seconds: 5),
      ),
    );
    return;
  }

  await Navigator.of(context).push(
    MaterialPageRoute<void>(builder: (_) => const LiveScreen()),
  );
}

/// 진행 중 표시용 모달. 자기 자신의 route context를 기억해 두었다가 닫으므로,
/// 그 사이 다른 화면이 push/pop 돼도 엉뚱한 라우트를 닫지 않는다.
class _BusyDialog {
  BuildContext? _dialogContext;
  bool _closed = false;

  void show(BuildContext context, String label) {
    unawaited(showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        _dialogContext = ctx;
        return PopScope(
          canPop: false,
          child: Dialog(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 22, 24, 22),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(strokeWidth: 2.5),
                  ),
                  const SizedBox(width: 18),
                  Text(label, style: Theme.of(ctx).textTheme.titleMedium),
                ],
              ),
            ),
          ),
        );
      },
    ));
  }

  void close() {
    if (_closed) return;
    _closed = true;
    final ctx = _dialogContext;
    if (ctx != null && ctx.mounted) Navigator.of(ctx).pop();
  }
}

/// 라이브 청취 화면. 라이브는 탐색·배속·이전/다음이 의미가 없어 컨트롤은
/// 재생/정지 하나뿐이고, 대신 이퀄라이저 애니메이션으로 스트리밍 중임을 보인다.
class LiveScreen extends StatefulWidget {
  const LiveScreen({super.key});

  @override
  State<LiveScreen> createState() => _LiveScreenState();
}

class _LiveScreenState extends State<LiveScreen> {
  static const Color _accent = Color(0xFFE4D7B0);
  static const Color _bg = Color(0xFF0C0C0C);
  static const Color _live = Color(0xFFFF3B30);

  bool _playing = false;
  ProcessingState _processing = ProcessingState.idle;
  StreamSubscription<PlayerState>? _stateSub;

  @override
  void initState() {
    super.initState();
    debugPrint('[BT] screen: LiveScreen 진입');
    _playing = btPlayer.playing;
    _processing = btPlayer.processingState;
    _stateSub = btPlayer.playerStateStream.listen((s) {
      if (!mounted) return;
      setState(() {
        _playing = s.playing;
        _processing = s.processingState;
      });
    });
  }

  @override
  void dispose() {
    debugPrint('[BT] screen: LiveScreen 이탈');
    // 화면을 나가도 재생은 계속된다(백그라운드 청취가 목적).
    // LiveSession도 그대로 살아 있어 만료 갱신/재연결을 이어간다.
    _stateSub?.cancel();
    super.dispose();
  }

  bool get _buffering =>
      _processing == ProcessingState.loading ||
      _processing == ProcessingState.buffering;

  String get _statusLabel {
    if (_buffering) return '버퍼링 중...';
    if (_playing) return '실시간 스트리밍 중';
    return '정지됨';
  }

  Future<void> _toggle() async {
    debugPrint('[BT] live: ${_playing ? "정지" : "재생"} 버튼');
    try {
      await LiveSession.instance.togglePlay();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e is LiveUnavailableException
            ? '$e'
            : '재생하지 못했습니다: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final info = LiveSession.instance.current;
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
        title: const Text(
          '한국경제Live',
          style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
        ),
      ),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            const Spacer(),
            _buildLiveBadge(),
            const SizedBox(height: 28),
            _EqualizerBars(
              active: _playing && !_buffering,
              color: _accent,
            ),
            const SizedBox(height: 36),
            _buildTitle(info),
            const SizedBox(height: 10),
            Text(
              _statusLabel,
              style: const TextStyle(fontSize: 13, color: Colors.white38),
            ),
            const Spacer(),
            _buildButton(),
            const SizedBox(height: 44),
          ],
        ),
      ),
    );
  }

  Widget _buildLiveBadge() {
    final on = _playing && !_buffering;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      decoration: BoxDecoration(
        color: on ? _live.withValues(alpha: 0.16) : Colors.white10,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: on ? _live.withValues(alpha: 0.7) : Colors.white24,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: on ? _live : Colors.white38,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            'LIVE',
            style: TextStyle(
              fontSize: 12,
              letterSpacing: 1.5,
              fontWeight: FontWeight.w700,
              color: on ? _live : Colors.white38,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTitle(LiveStreamInfo? info) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Column(
        children: [
          Text(
            info?.title ?? '한국경제TV LIVE',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 21,
              fontWeight: FontWeight.bold,
              color: Colors.white,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            info?.author ?? '한국경제TV',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 14, color: Colors.white54),
          ),
        ],
      ),
    );
  }

  Widget _buildButton() {
    return GestureDetector(
      onTap: _toggle,
      child: Container(
        width: 78,
        height: 78,
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
          _playing ? Icons.stop_rounded : Icons.play_arrow_rounded,
          color: const Color(0xFF1A1A1A),
          size: 40,
        ),
      ),
    );
  }
}

/// 스트리밍 중임을 보여주는 이퀄라이저 막대.
///
/// just_audio는 실제 오디오 레벨을 주지 않으므로(iOS는 특히), 재생 중일 때
/// 막대마다 다른 주기·위상의 사인파로 높이를 흔들어 "소리가 나가는 중"이라는
/// 느낌만 만든다. 정지 상태에서는 애니메이션을 멈추고 낮게 눕힌다.
class _EqualizerBars extends StatefulWidget {
  final bool active;
  final Color color;

  const _EqualizerBars({required this.active, required this.color});

  @override
  State<_EqualizerBars> createState() => _EqualizerBarsState();
}

class _EqualizerBarsState extends State<_EqualizerBars>
    with SingleTickerProviderStateMixin {
  static const int _barCount = 7;
  static const double _maxHeight = 96;
  static const double _idleFraction = 0.12;

  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  );

  // 막대별 주기 배수와 위상. 규칙적으로 보이지 않게 서로 어긋나게 둔다.
  static const List<double> _speeds = [1.0, 1.6, 1.25, 2.1, 1.45, 1.85, 1.15];
  static const List<double> _phases = [0.0, 0.35, 0.7, 0.15, 0.55, 0.85, 0.45];

  @override
  void initState() {
    super.initState();
    if (widget.active) _controller.repeat();
  }

  @override
  void didUpdateWidget(covariant _EqualizerBars old) {
    super.didUpdateWidget(old);
    if (widget.active && !_controller.isAnimating) {
      _controller.repeat();
    } else if (!widget.active && _controller.isAnimating) {
      _controller.stop();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  double _fractionFor(int i, double t) {
    if (!widget.active) return _idleFraction;
    final wave = sin(2 * pi * (t * _speeds[i] + _phases[i]));
    // 0.18 ~ 1.0 사이를 오가게 정규화.
    return 0.18 + ((wave + 1) / 2) * 0.82;
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: _maxHeight,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) {
          final t = _controller.value;
          return Row(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: List.generate(_barCount, (i) {
              final h = (_maxHeight * _fractionFor(i, t)).clamp(6.0, _maxHeight);
              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 5),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 120),
                  width: 10,
                  height: h,
                  decoration: BoxDecoration(
                    color: widget.active
                        ? widget.color
                        : widget.color.withValues(alpha: 0.25),
                    borderRadius: BorderRadius.circular(5),
                  ),
                ),
              );
            }),
          );
        },
      ),
    );
  }
}
