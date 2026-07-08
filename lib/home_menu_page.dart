import 'package:flutter/material.dart';

import 'main.dart' show WebViewPage;
import 'player_service.dart';
import 'saved_audio_page.dart';

/// 앱 진입 시 보여주는 메뉴. 저장파일 / 유튜브라이브 중 선택한다.
class HomeMenuPage extends StatelessWidget {
  const HomeMenuPage({super.key});

  /// 재생 화면은 공유 플레이어를 만들므로, 진입 전에 오디오 초기화 완료를 보장한다.
  /// (앱 시작 시 백그라운드로 시작해 둔 초기화라 보통 이미 끝나 즉시 진입한다.)
  Future<void> _open(BuildContext context, Widget page) async {
    debugPrint('[BT] nav: HomeMenu → ${page.runtimeType}');
    await ensureAudioReady();
    if (!context.mounted) return;
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => page));
  }

  @override
  Widget build(BuildContext context) {
    debugPrint('[BT] boot: HomeMenuPage build');
    return Scaffold(
      appBar: AppBar(
        title: const Text('BackTube'),
        centerTitle: true,
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _MenuCard(
                    icon: Icons.folder_rounded,
                    label: '저장파일',
                    description: '기기에 저장한 오디오 재생',
                    onTap: () => _open(context, const SavedAudioPage()),
                  ),
                  const SizedBox(height: 20),
                  _MenuCard(
                    icon: Icons.smart_display_rounded,
                    label: '유튜브라이브',
                    description: '유튜브 열기 · 백그라운드 재생',
                    onTap: () => _open(context, const WebViewPage()),
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

class _MenuCard extends StatelessWidget {
  final IconData icon;
  final String label;
  final String description;
  final VoidCallback onTap;

  const _MenuCard({
    required this.icon,
    required this.label,
    required this.description,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      width: double.infinity,
      child: Card(
        elevation: 2,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
            child: Row(
              children: [
                Icon(icon, size: 40, color: theme.colorScheme.primary),
                const SizedBox(width: 20),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        label,
                        style: theme.textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        description,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                const Icon(Icons.chevron_right_rounded),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
