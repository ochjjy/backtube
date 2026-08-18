#!/usr/bin/env bash
# 아이폰에 빌드해서 올리는 스크립트.
#
#   tool/deploy_ios.sh              빌드 + 설치 + 실행, [BT] 로그를 터미널에 흘린다
#   tool/deploy_ios.sh --install    빌드 + 설치만(실행/로그 없음)
#   tool/deploy_ios.sh --logs       이미 깔린 앱의 로그만 본다
#   tool/deploy_ios.sh --clean      flutter clean 후 처음부터 빌드
#   tool/deploy_ios.sh --debug      릴리즈 대신 디버그로(핫리로드용)
#
# 릴리즈로 올리는 이유: 실기기 디버그 실행은 "connecting to vmService"에서 멈추는
# 일이 잦다(AGENTS.md §3). 릴리즈에서도 `debugPrint`는 그대로 출력되므로 [BT]
# 로그는 다 보인다.
set -euo pipefail

cd "$(dirname "$0")/.."

# Flutter SDK: PATH에 없으면 알려진 위치를 쓴다(AGENTS.md 툴체인 항목).
if ! command -v flutter >/dev/null 2>&1; then
  export PATH="$HOME/work/kwic/flutter/flutter/bin:$PATH"
fi
command -v flutter >/dev/null 2>&1 || {
  echo "flutter를 찾지 못했습니다. PATH를 확인하세요." >&2
  exit 1
}

MODE=run
BUILD_MODE=--release
for arg in "$@"; do
  case "$arg" in
    --install) MODE=install ;;
    --logs)    MODE=logs ;;
    --clean)   MODE=clean ;;
    --debug)   BUILD_MODE=--debug ;;
    -h|--help) sed -n '2,12p' "$0" | sed -e 's/^#//' -e 's/^ //'; exit 0 ;;
    *) echo "모르는 옵션: $arg" >&2; exit 1 ;;
  esac
done

# 연결된 iOS 기기를 자동으로 찾는다(유선/무선 모두).
DEVICE_ID=$(flutter devices --machine 2>/dev/null | python3 -c "
import json, sys
try:
    devices = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for d in devices:
    if d.get('targetPlatform', '').startswith('ios'):
        print(d['id'])
        break
")

if [ -z "$DEVICE_ID" ]; then
  echo "연결된 iOS 기기가 없습니다." >&2
  echo "  · USB로 연결하거나, Xcode에서 무선 연결을 켜 두세요." >&2
  echo "  · 기기가 잠겨 있으면 잠금을 해제하고 '이 컴퓨터를 신뢰'를 눌러야 합니다." >&2
  exit 1
fi

DEVICE_NAME=$(flutter devices --machine 2>/dev/null | python3 -c "
import json, sys
for d in json.load(sys.stdin):
    if d.get('id') == '$DEVICE_ID':
        print(d.get('name', '?'))
        break
")
echo "▶ 기기: $DEVICE_NAME ($DEVICE_ID)"

if [ "$MODE" = clean ]; then
  echo "▶ flutter clean"
  flutter clean
  flutter pub get
  MODE=run
fi

case "$MODE" in
  logs)
    echo "▶ 로그만 표시 (Ctrl+C로 종료). [BT] 로 시작하는 줄이 앱 로그입니다."
    exec flutter logs -d "$DEVICE_ID"
    ;;
  install)
    echo "▶ 빌드 ($BUILD_MODE)"
    flutter build ios "$BUILD_MODE"
    echo "▶ 설치"
    flutter install -d "$DEVICE_ID"
    echo "✅ 설치 완료. 로그를 보려면: tool/deploy_ios.sh --logs"
    ;;
  run)
    echo "▶ 빌드 + 설치 + 실행 ($BUILD_MODE). Ctrl+C로 종료."
    echo "  [BT] 로그가 이 터미널에 그대로 나옵니다."
    exec flutter run "$BUILD_MODE" -d "$DEVICE_ID"
    ;;
esac
