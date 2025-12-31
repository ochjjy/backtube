import 'package:flutter/material.dart';

import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'package:audio_service/audio_service.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

class AudioPlayerPage extends StatefulWidget {
  final String videoId;
  final double position;
  const AudioPlayerPage({super.key, required this.videoId, required this.position});

  @override
  State<AudioPlayerPage> createState() => _AudioPlayerPageState();
}

class _AudioPlayerPageState extends State<AudioPlayerPage> {
  late final AudioPlayer _player;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _player = AudioPlayer();
    _init();
  }

  Future<void> _init() async {
    setState(() { _loading = true; });
    try {
      final yt = YoutubeExplode();
      final video = await yt.videos.get(widget.videoId);
      final manifest = await yt.videos.streamsClient.getManifest(widget.videoId);
      final audio = manifest.audioOnly.withHighestBitrate();
      final url = audio.url.toString();
      final mediaItem = MediaItem(
        id: widget.videoId,
        title: video.title,
        artist: video.author,
        duration: video.duration,
        artUri: null, // 썸네일 대신 시스템 기본 배경 사용
      );
      await _player.setAudioSource(
        ConcatenatingAudioSource(children: [
          AudioSource.uri(Uri.parse(url), tag: mediaItem),
          AudioSource.uri(Uri.parse(url), tag: mediaItem),
        ]),
        initialPosition: Duration(seconds: widget.position.toInt()),
      );
      // 자동 재생 제거: 플레이 버튼을 눌러야만 재생됨
      yt.close();
    } catch (e) {
      // ignore
    }
    setState(() { _loading = false; });
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('BackTube 오디오')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : GestureDetector(
              onHorizontalDragEnd: (details) {
                if (details.primaryVelocity != null) {
                  if (details.primaryVelocity! < 0) {
                    // 오른쪽 → 왼쪽 스와이프: 다음 곡
                    _player.seekToNext();
                  } else if (details.primaryVelocity! > 0) {
                    // 왼쪽 → 오른쪽 스와이프: 이전 곡
                    _player.seekToPrevious();
                  }
                }
              },
              child: DraggableScrollableSheet(
                initialChildSize: 0.2,
                minChildSize: 0.1,
                maxChildSize: 0.4,
                builder: (context, scrollController) {
                  return Container(
                    decoration: const BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
                      boxShadow: [
                        BoxShadow(color: Colors.black26, blurRadius: 8),
                      ],
                    ),
                    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                    child: ListView(
                      controller: scrollController,
                      children: [
                        Center(
                          child: Container(
                            width: 40,
                            height: 4,
                            margin: const EdgeInsets.only(bottom: 16),
                            decoration: BoxDecoration(
                              color: Colors.grey[300],
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                        ),
                        StreamBuilder<PlayerState>(
                          stream: _player.playerStateStream,
                          builder: (context, snapshot) {
                            final playing = snapshot.data?.playing ?? false;
                            return Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                IconButton(
                                  icon: const Icon(Icons.replay_10, size: 40),
                                  onPressed: () {
                                    final pos = _player.position;
                                    _player.seek(Duration(seconds: (pos.inSeconds - 10).clamp(0, pos.inSeconds)));
                                  },
                                ),
                                IconButton(
                                  icon: Icon(playing ? Icons.pause : Icons.play_arrow, size: 56),
                                  onPressed: () {
                                    if (playing) {
                                      _player.pause();
                                    } else {
                                      _player.play();
                                    }
                                  },
                                ),
                                IconButton(
                                  icon: const Icon(Icons.forward_10, size: 40),
                                  onPressed: () {
                                    final pos = _player.position;
                                    final dur = _player.duration ?? Duration.zero;
                                    _player.seek(Duration(seconds: (pos.inSeconds + 10).clamp(0, dur.inSeconds)));
                                  },
                                ),
                              ],
                            );
                          },
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
    );
  }
}
// AudioPlayerTask 등 audio_service 연동은 필요시 별도 구현
