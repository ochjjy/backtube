import 'package:flutter/material.dart';

import 'main.dart' show WebViewPage;
import 'player_service.dart';
import 'saved_audio_page.dart';

/// 앱 진입 시 보여주는 메뉴. 저장파일 / 유튜브라이브 중 선택한다.
class HomeMenuPage extends StatelessWidget {
  const HomeMenuPage({super.key});

  /// 재생 화면은 공유 플레이어를 만들므로, 진입 전에 오디오 초기화 완료를 보장한다.
  /// 초기화는 앱 시작 시 백그라운드로 시작해 두므로 보통 이미 끝나 즉시 진입한다.
  /// 아직 진행 중이면(초기화가 수 초 걸릴 수 있음) "초기화 중" 팝업을 띄우고,
  /// 완료되면 팝업을 닫고 자동으로 진입한다.
  Future<void> _open(BuildContext context, Widget page) async {
    debugPrint('[BT] nav: HomeMenu → ${page.runtimeType} (audioReady=$audioReady)');
    if (!audioReady) {
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => const _InitializingDialog(),
      );
      try {
        await ensureAudioReady();
      } catch (_) {}
      if (!context.mounted) return;
      Navigator.of(context, rootNavigator: true).pop(); // 초기화 팝업 닫기
    }
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

/// 오디오 초기화가 끝날 때까지 잠깐 띄우는 "초기화 중" 팝업.
/// 사용자가 임의로 닫아 진입 흐름과 어긋나지 않도록 뒤로가기/바깥탭을 막고,
/// 초기화가 끝나면 _open이 자동으로 닫는다.
class _InitializingDialog extends StatelessWidget {
  const _InitializingDialog();

  @override
  Widget build(BuildContext context) {
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
              Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '초기화 중...',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '잠시만 기다려 주세요',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
