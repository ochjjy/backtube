import 'dart:async';
import 'dart:math';

import 'package:audio_session/audio_session.dart';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';

import 'download_service.dart';
import 'player_screen.dart';
import 'player_service.dart';

/// 기기에 저장된 오디오 목록을 보여주고 백그라운드 재생한다.
/// 재생은 앱 공유 플레이어(btPlayer)를 사용한다.
/// 루트/서브폴더(1단계)를 탐색하고, 파일을 폴더로 드래그해 이동할 수 있다.
class SavedAudioPage extends StatefulWidget {
  const SavedAudioPage({super.key});

  @override
  State<SavedAudioPage> createState() => _SavedAudioPageState();
}

class _SavedAudioPageState extends State<SavedAudioPage> {
  static const List<double> _speeds = [1.0, 1.25, 1.5, 1.75, 2.0];

  String? _currentFolder; // null = 루트
  List<String> _folders = [];
  List<SavedAudio> _items = [];
  bool _loading = true;
  String? _currentVideoId;
  double _speed = 1.0;
  LoopMode _loopMode = LoopMode.off;
  StreamSubscription<PlayerState>? _playerStateSub;
  StreamSubscription<int?>? _indexSub;

  @override
  void initState() {
    super.initState();
    debugPrint('[BT] screen: SavedAudioPage 진입');
    // 저장파일 재생 중이면(예: 이 화면을 떠났다 돌아온 경우) 현재 곡을 표시한다.
    // 단, 유튜브 웹이 백그라운드용으로 준비만 해 둔 소스는 저장곡이 아니므로
    // 무시한다. 안 그러면 방금 보던 영상을 그대로 저장한 경우 videoId가 겹쳐,
    // 파일을 탭했을 때 _play(파일 로드)가 아니라 남은 웹 소스 토글로 새어 나가
    // 저장 파일이 재생되지 않는다.
    if (btPlaybackOrigin == BtPlaybackOrigin.saved) {
      final tag = btPlayer.sequenceState.currentSource?.tag;
      if (tag is MediaItem) _currentVideoId = tag.id;
    }
    _speed = btPlayer.speed;
    _loopMode = btPlayer.loopMode;
    _playerStateSub = btPlayer.playerStateStream.listen((_) {
      if (mounted) setState(() {});
    });
    // 플레이리스트가 다음 곡으로 넘어가면 현재곡 하이라이트를 따라가게 한다.
    _indexSub = btPlayer.currentIndexStream.listen((_) {
      _syncCurrentFromPlayer();
    });
    _load();
  }

  void _syncCurrentFromPlayer() {
    final tag = btPlayer.sequenceState.currentSource?.tag;
    if (mounted && tag is MediaItem && tag.id != _currentVideoId) {
      setState(() => _currentVideoId = tag.id);
    }
  }

  @override
  void dispose() {
    debugPrint('[BT] screen: SavedAudioPage 이탈');
    _playerStateSub?.cancel();
    _indexSub?.cancel();
    // btPlayer는 공유 인스턴스이므로 dispose 하지 않는다.
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final folders = _currentFolder == null
          ? await DownloadService.listFolders()
          : <String>[];
      final items = await DownloadService.list(folder: _currentFolder);
      if (!mounted) return;
      setState(() {
        _folders = folders;
        _items = items;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _folders = [];
        _items = [];
        _loading = false;
      });
    }
  }

  void _openFolder(String name) {
    setState(() => _currentFolder = name);
    _load();
  }

  void _goRoot() {
    setState(() => _currentFolder = null);
    _load();
  }

  Future<void> _promptCreateFolder() async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('새 폴더'),
        content: TextField(
          controller: controller,
          autofocus: true,
          textInputAction: TextInputAction.done,
          decoration: const InputDecoration(hintText: '폴더 이름'),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('취소')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, controller.text),
              child: const Text('만들기')),
        ],
      ),
    );
    controller.dispose();
    if (name == null) return;

    final clean = DownloadService.sanitizeFolderName(name);
    if (clean.isEmpty) {
      _snack('폴더 이름을 입력하세요');
      return;
    }
    if (await DownloadService.folderExists(clean)) {
      _snack('이미 있는 폴더: $clean');
      return;
    }
    await DownloadService.createFolder(clean);
    await _load();
  }

  Future<void> _moveTo(SavedAudio item, String? toFolder) async {
    if (toFolder == _currentFolder) return;
    // 재생 중인 파일을 옮기면 경로가 바뀌므로 정지 후 이동한다(안전).
    if (_currentVideoId == item.videoId) {
      await btPlayer.stop();
      _currentVideoId = null;
    }
    await DownloadService.move(item.videoId, from: _currentFolder, to: toFolder);
    await _load();
    _snack(toFolder == null ? '루트로 이동했습니다' : '"$toFolder"(으)로 이동했습니다');
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 1)),
    );
  }

  String _fmtSpeed(double s) {
    var t = s.toStringAsFixed(2);
    if (t.contains('.')) {
      t = t.replaceAll(RegExp(r'0+$'), '').replaceAll(RegExp(r'\.$'), '');
    }
    return '$t×';
  }

  Future<void> _cycleSpeed() async {
    final idx = _speeds.indexWhere((s) => (s - _speed).abs() < 0.01);
    final next = _speeds[(idx + 1) % _speeds.length];
    try {
      await btPlayer.setSpeed(next);
      setState(() => _speed = next);
    } catch (e) {
      debugPrint('[BT] setSpeed error: $e');
    }
  }

  // 반복 없음 → 전체 반복 → 한 곡 반복 → 반복 없음.
  Future<void> _cycleRepeat() async {
    final next = switch (_loopMode) {
      LoopMode.off => LoopMode.all,
      LoopMode.all => LoopMode.one,
      LoopMode.one => LoopMode.off,
    };
    try {
      await btPlayer.setLoopMode(next);
      setState(() => _loopMode = next);
    } catch (e) {
      debugPrint('[BT] setLoopMode error: $e');
    }
  }

  String _repeatTooltip() => switch (_loopMode) {
        LoopMode.off => '반복 없음',
        LoopMode.all => '전체 반복',
        LoopMode.one => '한 곡 반복',
      };

  /// 한 곡을 just_audio 소스로 변환한다. 잠금화면 태그(제목/아트워크)와
  /// 2× duration 보정(ClippingAudioSource)을 포함한다.
  /// 저장곡 → 잠금화면/재생화면 표시용 MediaItem.
  MediaItem _mediaItemFor(SavedAudio item) {
    Uri? artUri;
    if (item.thumbPath != null) {
      artUri = Uri.file(item.thumbPath!);
    } else if (item.thumbUrl != null && item.thumbUrl!.isNotEmpty) {
      artUri = Uri.parse(item.thumbUrl!);
    }
    return MediaItem(
      id: item.videoId,
      title: item.title,
      artist: item.author.isEmpty ? 'BackTube' : item.author,
      duration: item.duration,
      artUri: artUri,
    );
  }

  AudioSource _sourceFor(SavedAudio item) {
    final mediaItem = _mediaItemFor(item);
    // 유튜브 androidVr 오디오 스트림은 컨테이너 duration이 실제의 2배로 들어와
    // AVPlayer가 2배 길이로 표시한다. 실제 길이만큼 잘라 잠금화면 길이를 바로잡는다.
    return (item.duration != null && item.duration! > Duration.zero)
        ? ClippingAudioSource(
            child: ProgressiveAudioSource(Uri.file(item.filePath)),
            start: Duration.zero,
            end: item.duration,
            tag: mediaItem,
          )
        : AudioSource.uri(Uri.file(item.filePath), tag: mediaItem);
  }

  /// 짧은 지연 후에도 재생이 안 걸렸으면 세션 재활성화 후 1회 재시도.
  /// (유튜브 재생 실패 잔해로 AVPlayer가 복구 중일 때 대비)
  Future<void> _playWithRetry(AudioSession session) async {
    btPlayIntent = true;
    await btPlayer.setSpeed(_speed);
    await btPlayer.play();
    await Future<void>.delayed(const Duration(milliseconds: 400));
    if (!btPlayer.playing) {
      // 그 사이 사용자가 일시정지를 눌렀다면(의도=정지) 재시도하지 않는다.
      // 안 그러면 자동 재시도가 사용자의 일시정지를 덮어써 다시 재생된다.
      if (!btPlayIntent) {
        debugPrint('[BT] saved play: 사용자 일시정지 감지 → 재시도 안 함');
        return;
      }
      debugPrint('[BT] saved play retry (player not started)');
      await session.setActive(true);
      if (btPlayIntent) await btPlayer.play();
    }
  }

  Future<void> _play(SavedAudio item) async {
    try {
      final session = await AudioSession.instance;
      await session.setActive(true);

      final prevTag = btPlayer.sequenceState.currentSource?.tag;
      final prevId = prevTag is MediaItem ? prevTag.id : null;
      debugPrint('[BT] saved play tap: file=${item.filePath} '
          'metaDuration=${item.duration} prevSourceId=$prevId '
          'prevPlayerDuration=${btPlayer.duration} playing=${btPlayer.playing}');

      // 이전 소스를 완전히 내리고 단일 재생으로 교체(셔플 끔, 반복은 사용자 설정).
      await btPlayer.stop();
      await btPlayer.setShuffleModeEnabled(false);
      await btPlayer.setLoopMode(_loopMode);
      await btPlayer.setAudioSource(_sourceFor(item));
      btPlaybackOrigin = BtPlaybackOrigin.saved;
      debugPrint('[BT] saved loaded: id=${item.videoId} '
          'playerDuration=${btPlayer.duration} metaDuration=${item.duration}');
      setState(() => _currentVideoId = item.videoId);
      await _playWithRetry(session);
    } catch (e) {
      _snack('재생 실패: $e');
    }
  }

  /// 현재 목록(_items) 전체를 플레이리스트로 재생한다.
  /// shuffle=false 순차재생, true 랜덤재생. 끝나면 자동으로 다음 곡으로 넘어가고,
  /// 잠금화면에도 이전/다음 버튼이 표시된다.
  Future<void> _playAll({required bool shuffle}) async {
    if (_items.isEmpty) return;
    final startIndex =
        (shuffle && _items.length > 1) ? Random().nextInt(_items.length) : 0;
    // 재생 화면을 먼저 띄우고(랜덤은 시작곡을 알 수 없어 힌트 생략), 무거운
    // 재생 셋업은 전환이 끝난 뒤 시작해 화면 전환을 매끄럽게 한다.
    _openPlayer(
      initial: shuffle ? null : _mediaItemFor(_items[startIndex]),
      onEntered: () =>
          unawaited(_startPlayAll(shuffle: shuffle, startIndex: startIndex)),
    );
  }

  Future<void> _startPlayAll({
    required bool shuffle,
    required int startIndex,
  }) async {
    try {
      final session = await AudioSession.instance;
      await session.setActive(true);

      final sources = _items.map(_sourceFor).toList();
      debugPrint('[BT] playAll shuffle=$shuffle count=${sources.length} '
          'start=$startIndex folder=$_currentFolder');

      await btPlayer.stop();
      await btPlayer.setLoopMode(_loopMode);
      await btPlayer.setShuffleModeEnabled(shuffle);
      await btPlayer.setAudioSources(sources, initialIndex: startIndex);
      btPlaybackOrigin = BtPlaybackOrigin.saved;
      if (shuffle) await btPlayer.shuffle();
      _syncCurrentFromPlayer();
      await _playWithRetry(session);
    } catch (e) {
      _snack('재생 실패: $e');
    }
  }

  /// 재생 화면을 연다. [onEntered]가 있으면 진입 전환 애니메이션이 끝난 뒤
  /// 호출한다. 무거운 오디오 셋업(session.setActive/setAudioSources/play 등은
  /// iOS 메인스레드에서 실행돼 전환 프레임을 막는다)을 전환 완료 후로 미뤄
  /// 화면 전환을 매끄럽게 하기 위함이다.
  void _openPlayer({MediaItem? initial, VoidCallback? onEntered}) {
    debugPrint('[BT] nav: SavedAudioPage → PlayerScreen (곡="${initial?.title}")');
    final route = MaterialPageRoute<void>(
      builder: (_) => PlayerScreen(initialMedia: initial),
    );
    Navigator.of(context).push(route);
    if (onEntered == null) return;

    // push 직후에는 route.animation이 아직 설치되지 않아 null일 수 있다. 이때
    // 고정 지연으로 발화하면 전환 "도중"에 무거운 작업이 끼어들어 애니메이션이
    // 반쯤에서 멈춘다. 다음 프레임(설치 완료 후)에 진입 애니메이션을 구독해,
    // 전환이 "완전히 끝난" 시점에만 onEntered를 호출한다.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final anim = route.animation;
      if (anim == null || anim.status == AnimationStatus.completed) {
        onEntered();
        return;
      }
      void listener(AnimationStatus status) {
        if (status == AnimationStatus.completed) {
          anim.removeStatusListener(listener);
          if (mounted) onEntered();
        } else if (status == AnimationStatus.dismissed) {
          // 전환이 끝나기 전에 되돌아갔으면(즉시 pop) 재생하지 않는다.
          anim.removeStatusListener(listener);
        }
      }

      anim.addStatusListener(listener);
    });
  }

  /// 파일 탭: 재생 화면을 즉시 띄우고, 다른 곡이면 전환이 끝난 뒤 재생을
  /// 시작한다(탭 즉시 전환 + 매끄러운 애니메이션). 재생 시작은 현재 목록을
  /// 큐로 만들어(이전/다음 동작) 그 곡부터 순차 재생한다.
  void _onTapItem(SavedAudio item) {
    debugPrint('[BT] tap: 곡 클릭 id=${item.videoId} title="${item.title}" '
        'currentId=$_currentVideoId');
    final isNewSong = _currentVideoId != item.videoId;
    if (!isNewSong) debugPrint('[BT] tap: 이미 현재 곡 → 재생화면만 열기');
    _openPlayer(
      initial: _mediaItemFor(item),
      onEntered: isNewSong
          ? () {
              debugPrint('[BT] tap: 전환 완료 → _playFrom 시작');
              unawaited(_playFrom(item));
            }
          : null,
    );
  }

  /// 현재 목록(_items)을 큐로 만들고 [item]부터 순차 재생한다.
  Future<void> _playFrom(SavedAudio item) async {
    final startIndex = _items.indexWhere((i) => i.videoId == item.videoId);
    debugPrint('[BT] playFrom: id=${item.videoId} index=$startIndex '
        'count=${_items.length} folder=$_currentFolder');
    if (startIndex < 0) {
      debugPrint('[BT] playFrom: index<0 → 단일재생(_play)');
      await _play(item);
      return;
    }
    try {
      // 어느 네이티브 호출이 UI를 멈추게 하는지 특정하기 위한 구간별 소요시간.
      final sw = Stopwatch()..start();
      int lap() {
        final ms = sw.elapsedMilliseconds;
        sw.reset();
        return ms;
      }

      final session = await AudioSession.instance;
      await session.setActive(true);
      debugPrint('[BT] playFrom.t: setActive=${lap()}ms');

      final sources = _items.map(_sourceFor).toList();
      debugPrint('[BT] playFrom.t: buildSources(${sources.length})=${lap()}ms');
      await btPlayer.stop();
      debugPrint('[BT] playFrom.t: stop=${lap()}ms');
      await btPlayer.setShuffleModeEnabled(false);
      await btPlayer.setLoopMode(_loopMode);
      await btPlayer.setAudioSources(sources, initialIndex: startIndex);
      debugPrint('[BT] playFrom.t: setAudioSources=${lap()}ms');
      btPlaybackOrigin = BtPlaybackOrigin.saved;
      setState(() => _currentVideoId = item.videoId);
      debugPrint('[BT] playFrom: setAudioSources 완료 → 재생 시도');
      await _playWithRetry(session);
      debugPrint('[BT] playFrom.t: playWithRetry=${lap()}ms');
      debugPrint('[BT] playFrom: 재생 상태 playing=${btPlayer.playing} '
          'dur=${btPlayer.duration}');
    } catch (e) {
      debugPrint('[BT] playFrom 실패: $e');
      _snack('재생 실패: $e');
    }
  }

  Future<void> _confirmDelete(SavedAudio item) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('삭제'),
        content: Text('"${item.title}" 을(를) 삭제할까요?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('취소'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('삭제'),
          ),
        ],
      ),
    );
    if (ok != true) return;

    if (_currentVideoId == item.videoId) {
      await btPlayer.stop();
      _currentVideoId = null;
    }
    await DownloadService.delete(item.videoId, folder: _currentFolder);
    await _load();
  }

  String _formatDuration(Duration? d) {
    if (d == null) return '';
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    final s = d.inSeconds.remainder(60);
    final mm = m.toString().padLeft(h > 0 ? 2 : 1, '0');
    final ss = s.toString().padLeft(2, '0');
    return h > 0 ? '$h:$mm:$ss' : '$mm:$ss';
  }

  @override
  Widget build(BuildContext context) {
    final isRoot = _currentFolder == null;
    return PopScope(
      canPop: isRoot,
      onPopInvokedWithResult: (didPop, _) {
        // 폴더 안에서 뒤로가기는 페이지를 떠나지 않고 루트로 올라간다.
        if (!didPop && !isRoot) _goRoot();
      },
      child: Scaffold(
        appBar: AppBar(
          leading: isRoot ? null : BackButton(onPressed: _goRoot),
          title: Text(isRoot ? '저장파일' : _currentFolder!),
          actions: [
            TextButton.icon(
              onPressed: _cycleSpeed,
              icon: const Icon(Icons.speed, size: 20),
              label: Text(_fmtSpeed(_speed)),
            ),
            IconButton(
              icon: Icon(
                _loopMode == LoopMode.one ? Icons.repeat_one : Icons.repeat,
              ),
              color: _loopMode == LoopMode.off
                  ? Theme.of(context).colorScheme.onSurfaceVariant
                  : Theme.of(context).colorScheme.primary,
              tooltip: _repeatTooltip(),
              onPressed: _cycleRepeat,
            ),
            if (isRoot)
              IconButton(
                icon: const Icon(Icons.create_new_folder_outlined),
                tooltip: '새 폴더',
                onPressed: _promptCreateFolder,
              ),
            IconButton(
              icon: const Icon(Icons.refresh),
              onPressed: _loading ? null : _load,
            ),
          ],
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : _buildBody(isRoot),
      ),
    );
  }

  Widget _buildBody(bool isRoot) {
    if (isRoot && _folders.isEmpty && _items.isEmpty) {
      return _buildEmptyRoot(context);
    }

    final children = <Widget>[
      if (_items.isNotEmpty) _buildPlayAllBar(),
      if (!isRoot) _buildRootDropTarget(),
      ..._folders.map(_buildFolderTile),
      ..._items.map(_buildFileTile),
      if (!isRoot && _items.isEmpty)
        const Padding(
          padding: EdgeInsets.all(32),
          child: Center(
            child: Text(
              '이 폴더에 오디오가 없습니다.\n파일을 폴더로 드래그해 옮길 수 있습니다.',
              textAlign: TextAlign.center,
            ),
          ),
        ),
    ];

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        physics: const AlwaysScrollableScrollPhysics(),
        itemCount: children.length,
        separatorBuilder: (_, __) => const Divider(height: 1),
        itemBuilder: (_, i) => children[i],
      ),
    );
  }

  Widget _buildPlayAllBar() {
    final count = _items.length;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Row(
        children: [
          Expanded(
            child: FilledButton.icon(
              onPressed: () => _playAll(shuffle: false),
              icon: const Icon(Icons.playlist_play),
              label: Text('전체재생 ($count)'),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: OutlinedButton.icon(
              onPressed: () => _playAll(shuffle: true),
              icon: const Icon(Icons.shuffle),
              label: const Text('랜덤재생'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRootDropTarget() {
    return DragTarget<SavedAudio>(
      onWillAcceptWithDetails: (_) => true,
      onAcceptWithDetails: (d) => _moveTo(d.data, null),
      builder: (context, candidate, rejected) {
        final hovering = candidate.isNotEmpty;
        final scheme = Theme.of(context).colorScheme;
        return Container(
          color: hovering
              ? scheme.primaryContainer
              : scheme.surfaceContainerHighest.withValues(alpha: 0.3),
          child: const ListTile(
            dense: true,
            leading: Icon(Icons.drive_file_move_outline),
            title: Text('여기로 드래그하면 루트로 이동'),
          ),
        );
      },
    );
  }

  Widget _buildFolderTile(String name) {
    final target = DragTarget<SavedAudio>(
      onWillAcceptWithDetails: (_) => true,
      onAcceptWithDetails: (d) => _moveTo(d.data, name),
      builder: (context, candidate, rejected) {
        final hovering = candidate.isNotEmpty;
        return Container(
          color: hovering
              ? Theme.of(context).colorScheme.primaryContainer
              : null,
          child: ListTile(
            leading: Icon(Icons.folder, color: Colors.amber.shade700, size: 32),
            title: Text(name,
                style: const TextStyle(fontWeight: FontWeight.w500)),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _openFolder(name),
          ),
        );
      },
    );

    // 좌로 슬라이드 → 폴더 삭제. 파일이 있으면 확인 메시지를 띄운다.
    return Dismissible(
      key: ValueKey('folder:$name'),
      direction: DismissDirection.endToStart,
      background: Container(
        color: Colors.red.shade700,
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 24),
        child: const Icon(Icons.delete, color: Colors.white),
      ),
      confirmDismiss: (_) => _confirmDeleteFolder(name),
      onDismissed: (_) => _deleteFolder(name),
      child: target,
    );
  }

  Future<bool> _confirmDeleteFolder(String name) async {
    final count = await DownloadService.folderFileCount(name);
    if (!mounted) return false;
    final msg = count > 0
        ? '"$name" 폴더에 파일 $count개가 있습니다. 모두 삭제할까요?'
        : '"$name" 폴더를 삭제할까요?';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('폴더 삭제'),
        content: Text(msg),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('취소')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('삭제')),
        ],
      ),
    );
    return ok == true;
  }

  Future<void> _deleteFolder(String name) async {
    // Dismissible 요구: 애니메이션 후 트리에서 즉시 제거.
    setState(() => _folders.remove(name));
    // 이 폴더의 곡이 재생 중이면 정지(삭제된 파일을 가리키지 않게).
    try {
      final items = await DownloadService.list(folder: name);
      if (_currentVideoId != null &&
          items.any((i) => i.videoId == _currentVideoId)) {
        await btPlayer.stop();
        _currentVideoId = null;
      }
    } catch (_) {}
    await DownloadService.deleteFolder(name);
    _snack('"$name" 폴더를 삭제했습니다');
    await _load();
  }

  Widget _buildFileTile(SavedAudio item) {
    final isCurrent = _currentVideoId == item.videoId;
    final isPlaying = isCurrent && btPlayer.playing;
    final tile = ListTile(
      leading: CircleAvatar(
        child: Icon(isPlaying ? Icons.pause : Icons.play_arrow),
      ),
      title: Text(
        item.title,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal,
        ),
      ),
      subtitle: Text(
        [
          if (item.author.isNotEmpty) item.author,
          if (item.duration != null) _formatDuration(item.duration),
        ].join(' · '),
      ),
      onTap: () => _onTapItem(item),
      trailing: IconButton(
        icon: const Icon(Icons.delete_outline),
        onPressed: () => _confirmDelete(item),
      ),
    );

    // 길게 눌러 드래그 → 폴더 타일(또는 루트 드롭영역)에 놓으면 이동.
    return LongPressDraggable<SavedAudio>(
      data: item,
      feedback: Material(
        elevation: 6,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          width: MediaQuery.of(context).size.width * 0.8,
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              const Icon(Icons.drag_indicator),
              const SizedBox(width: 8),
              Expanded(
                child: Text(item.title,
                    maxLines: 1, overflow: TextOverflow.ellipsis),
              ),
            ],
          ),
        ),
      ),
      childWhenDragging: Opacity(opacity: 0.35, child: tile),
      child: tile,
    );
  }

  Widget _buildEmptyRoot(BuildContext context) {
    final theme = Theme.of(context);
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: constraints.maxHeight),
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.library_music_outlined,
                      size: 64, color: theme.disabledColor),
                  const SizedBox(height: 16),
                  const Text(
                    '저장된 오디오가 없습니다.',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '유튜브라이브에서 영상의 "공유"를 누른 뒤\n"오디오로 저장"을 선택하면 여기에 추가됩니다.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
