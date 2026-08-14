# AGENTS.md — backtube

유튜브 영상을 **m4a로 기기에 저장해 백그라운드/오프라인 재생**하는 Flutter 앱. 개인용(publish_to: none), UI 문구·주석은 한국어.

동작 흐름은 두 갈래다:
1. **유튜브 웹뷰에서 "오디오로 저장" → 저장파일 화면에서 재생** (오프라인)
2. **한국경제Live → 헤드리스 파싱 → HLS 실시간 청취** (§2.3 참고)

웹뷰로 보던 영상을 백그라운드 진입 시 오디오로 이어받아 자동 재생하던 기능은 제거했다(§2.1) — 웹뷰는 이제 공유 플레이어를 건드리지 않는 순수 브라우저다.

주 사용 플랫폼은 **iOS 실기기**다. Android도 동작하지만 대부분의 까다로운 로직(AVPlayer 제약, 오디오 세션)은 iOS 때문에 존재한다.

---

## 1. 코드 지도

| 파일 | 역할 |
|---|---|
| [lib/main.dart](lib/main.dart) | `main()` + `WebViewPage`. m.youtube.com 웹뷰, 수평 스와이프 뒤로/앞으로, JS 주입(공유 가로채기 / ⋮메뉴에 "오디오로 저장" 항목), 저장 진행 다이얼로그. 오디오 재생 코드는 없다. |
| [lib/player_service.dart](lib/player_service.dart) | 앱 전역 단일 `btPlayer`(AudioPlayer), `btPlaybackOrigin`, `btPlayIntent`, `ensureAudioReady()` / `audioReady`. |
| [lib/download_service.dart](lib/download_service.dart) | m4a 다운로드·저장·폴더(1단계) 관리, 사이드카 메타(`<videoId>.json`)·썸네일(`<videoId>.jpg`), 실패 사유 진단(`_diagnoseUnavailable`), `AudioUnavailableException`, 저장 취소(`DownloadCancelToken`). |
| [lib/yt_audio_language.dart](lib/yt_audio_language.dart) | `withAudioLanguage()`(클라이언트 `hl` 덮어쓰기), `preferDefaultAudioTrack()`. 자동 더빙 영상의 언어 오선택 방지. |
| [lib/live_service.dart](lib/live_service.dart) | 한국경제Live. 한경 페이지를 **헤드리스로 파싱**해 유튜브 라이브 id → InnerTube(ANDROID)로 HLS 획득 → 최저 대역 변형 선택. `LiveSession`이 만료 갱신·재연결을 유지한다. |
| [lib/live_screen.dart](lib/live_screen.dart) | `openLiveAudio()` 진입 함수 + 라이브 청취 화면(재생/정지 버튼 하나 + 이퀄라이저 애니메이션). |
| [lib/saved_audio_page.dart](lib/saved_audio_page.dart) | 저장파일 목록/폴더 탐색·드래그 이동·삭제, 단일/전체/랜덤 재생 큐 구성. |
| [lib/player_screen.dart](lib/player_screen.dart) | 재생 화면. 소스를 로드하지 않고 `btPlayer` 스트림만 구독해 표시(원형 진행바 드래그 시크). |
| [lib/home_menu_page.dart](lib/home_menu_page.dart) | 진입 메뉴(저장파일 / 유튜브라이브). 진입 전 `ensureAudioReady()` 보장. |
| [tool/yt_probe.dart](tool/yt_probe.dart) | youtube_explode가 아직 스트림을 뽑는지 검증. |
| [tool/yt_track_probe.dart](tool/yt_track_probe.dart) | 오디오 트랙(언어) 진단. |
| [tool/wowtv_live_probe.dart](tool/wowtv_live_probe.dart) | 한국경제Live 3단계(페이지 파싱 → InnerTube → HLS) 진단. |

의존성: `webview_flutter`, `just_audio` + `just_audio_background` + `audio_session`(+`audio_service`), `youtube_explode_dart`, `path_provider`.

---

## 2. 절대 깨뜨리면 안 되는 규칙

### 2.1 웹뷰는 공유 플레이어를 건드리지 않는다 (백그라운드 자동 재생 제거됨)
과거 `WebViewPage`는 3초 주기로 유튜브 오디오 스트림을 미리 로드해 두었다가 백그라운드 진입 시 자동 재생했다. 이 경로 전체(선로딩 타이머, `_prepareBackgroundAudio`/`_loadPlayableAudio`, `_playWhenPrepared`/`_disposed` 가드, 매니페스트 만료 갱신·에러 복구, 재생 오버레이, iOS `beginBackgroundTask` 유예와 `backtube/lifecycle` MethodChannel)를 **제거했다**.

되살릴 생각이라면 그 코드가 왜 그렇게 복잡했는지부터 알 것: 공유 플레이어를 두 화면이 겹쳐 쓰면서 "보던 영상을 그대로 저장한 뒤 재생하면 무음"이 되는 버그가 있었고, `btPlaybackOrigin`(none/web/saved)과 dispose 후 늦게 도착하는 비동기 로더 가드가 그 대응책이었다. `BtPlaybackOrigin.web`은 그 흔적으로 남아 있으나 현재 아무도 세팅하지 않는다.

지금 살아 있는 규칙:
- `btPlayer`(`just_audio_background` 전제)는 앱 전역 단일 인스턴스라 **어디서도 dispose 하지 않는다**. 재생성하면 iOS 오디오 세션과 잠금화면/제어센터 바인딩이 끊긴다.
- 소스를 로드하면 `btPlaybackOrigin = saved`를 세팅한다. `SavedAudioPage`는 `origin == saved`일 때만 현재 곡을 물려받는다.
- 사용자의 재생/일시정지 의도는 `btPlayIntent`에 남긴다. 자동 재시도(`_playWithRetry`)가 사용자의 일시정지를 되살리지 않도록.

### 2.2 iOS AVPlayer는 webm/opus를 재생하지 못한다
시도만 해도 `-11828` 실패 + XPC 파이프라인 크래시로 **이후 로드까지 연쇄 실패**한다. 저장 스트림 선택(`_resolveAudioStream`)은 iOS에서 **mp4/AAC만** 후보로 둔다(Android는 opus 폴백 유지). 유튜브 스트림을 직접 재생하는 코드를 새로 만든다면 같은 제약을 그대로 지킬 것.

### 2.3 클라이언트 시도 순서 — 저장과 라이브가 **다르다**
저장(`_resolveAudioStream`)은 `ios → androidVr → default`. `ios`가 AVPlayer와 가장 잘 맞지만 매니페스트가 403인 영상이 있고, `default`(ANDROID)는 매니페스트는 나와도 AVPlayer가 로드 못 하는 경우가 있어 마지막 폴백이다. mp4가 없는 클라이언트는 건너뛴다.

**라이브는 반대다.** 실측(2026-07-31, 한국경제TV LIVE) 결과:

| 클라이언트 | 라이브 결과 |
|---|---|
| ANDROID | `OK` + `hlsManifestUrl` ✅ |
| IOS | `UNPLAYABLE` "동영상이 처리 중입니다" |
| WEB / MWEB | `UNPLAYABLE` |
| TVHTML5 | `LOGIN_REQUIRED`(봇 확인) |

그래서 `live_service.dart`는 ANDROID 컨텍스트로만 InnerTube를 호출한다. **"일관성"을 이유로 ios 우선으로 통일하지 말 것.** `youtube_explode`의 `getHttpLiveStreamUrl()`도 watch 페이지 스크래핑 방식이라 실패하므로 쓰지 않는다.

### 2.3.1 라이브의 제약
- **저장(m4a) 불가.** 라이브는 progressive/adaptive 포맷이 발행되지 않는다(§3의 post-live 항목과 같은 원인). 저장은 방송 종료 후 VOD가 준비된 뒤에만.
- **오디오 전용 스트림은 iOS에서 얻을 수 없다**(2026-07-31 실측). HLS master에 `EXT-X-MEDIA`가 0개고 6개 변형이 전부 muxed A/V다. 확인한 우회로와 결과:

  | 시도 | 결과 |
  |---|---|
  | 다른 InnerTube 클라이언트(ANDROID_VR/MUSIC/EMBEDDED 등 6종) | 전부 `LOGIN_REQUIRED`/`ERROR`, 또는 ANDROID와 동일한 muxed 매니페스트 |
  | `hls_variant` URL에 `/maudio/1/` 삽입 | HTTP 403 (URL이 서명돼 있어 경로 변조 불가) |
  | `adaptiveFormats`의 오디오 itag 139/140 직접 재생 | 라이브 세그먼트 엔드포인트라 일반 GET은 무한 대기, `sq=0`은 404 |
  | DASH 매니페스트(오디오 전용 표현 있음) | AVPlayer가 DASH 미지원. Android도 `just_audio`가 `DefaultRenderersFactory`(비디오 렌더러 포함)를 쓰고 비디오 트랙 선택을 끄지 않아 절감 효과 없음 |

  따라서 최소치는 **최저 변형(144p, 실측 약 228kbps ≈ 시간당 98MB)** 이고, `_pickLowestBitrateVariant`가 이를 고정한다. 음질을 올리려면 360p 변형(오디오 128k AAC-LC, 약 1Mbps)으로 바꾼다.
- 데이터 절약 장치 3종: ⑴ 최저 변형 명시 선택, ⑵ `player_service.dart`의 `preferredPeakBitRate: 320000`(변형 선택 실패로 master에 폴백해도 1080p 4.5Mbps를 고르지 못하게 막는 안전장치), ⑶ `canUseNetworkResourcesForLiveStreamingWhilePaused: false`(정지 중 다운로드 없음). 아트워크도 maxres 대신 320px급을 고른다.
- 세그먼트 1초, 라이브 윈도우 3개 → **seek·배속 불가**, `duration`은 null. 그래서 라이브 화면은 재생/정지 버튼 하나만 둔다.
- 매니페스트 `expire` ≈ 6시간 → `LiveSession`이 만료 10분 전에 재발급한다.
- **세션이 살아 있으면(`LiveSession.isActive`) 메뉴에서 다시 눌러도 재해석하지 않는다.** `openLiveAudio`는 그 경우 `LiveScreen`만 push한다. `start()`는 `stop()` → 한경 페이지 재파싱 → 소스 재로드라, 듣고 있던 방송이 끊긴다. `isActive`가 `btPlaybackOrigin == live`까지 보므로 그 사이 저장파일 재생이 끼어들었으면 정상적으로 새로 시작한다.

### 2.4 오디오 언어는 `hl`로 고른다
내장 `YoutubeApiClient`는 `hl:'en'`이 하드코딩돼 있어, 자동 더빙 영상이 **영어 더빙 트랙을 default로** 내려준다. 스트림을 가져오는 모든 경로는 `withAudioLanguage(client)`(hl=ko)를 거치고, 매니페스트는 `preferDefaultAudioTrack()`으로 걸러야 한다(비트레이트 정렬만 하면 더빙 트랙이 더 높아 오염된다). `gl`(지역)은 지역제한 영상을 깨뜨리므로 건드리지 않는다.

### 2.4.1 `btPlayer.play()`를 await 하지 말 것
just_audio의 `play()`가 돌려주는 Future는 **재생이 시작될 때가 아니라 재생이 끝나거나 일시정지/정지될 때** 완료된다(패키지 문서에 명시). 라이브처럼 끝나지 않는 소스에서 `await btPlayer.play()`를 하면 호출한 함수가 영영 반환되지 않는다 — 실제로 "라이브 연결 중" 팝업이 안 닫히고 `LiveSession._busy`가 풀리지 않아 만료 갱신까지 멈추는 버그가 났다. 재생 시작만 필요하면 `unawaited(btPlayer.play())`를 쓰고, 시작 여부는 `playerStateStream`으로 확인한다.

### 2.5 오디오 세션 활성화 타이밍
[ios/Runner/AppDelegate.swift](ios/Runner/AppDelegate.swift)는 카테고리(`.playback`)만 설정하고 **`setActive`는 하지 않는다**. 앱 실행만으로 다른 앱 음악을 끊지 않기 위함이며, 활성화(`session.setActive(true)`)는 Dart 쪽에서 **재생 직전에** 한다(`SavedAudioPage._play`/`_playFrom`/`_startPlayAll`). 세션이 죽은 상태로 로드하면 iOS에서 `-11800/-11819`로 실패한다.

백그라운드 재생 자체는 `UIBackgroundModes: audio`(iOS)와 `AudioService` 포그라운드 서비스(Android)가 담당한다 — 이미 재생 중인 오디오는 백그라운드로 가도 이어진다.

### 2.6 오디오 초기화는 첫 프레임을 막지 않는다
`main()`은 `ensureAudioReady()`를 `unawaited`로 시작만 하고 `runApp`한다(초기화가 기기에 따라 수 초). 대신 **플레이어를 실제로 쓰기 직전**(`HomeMenuPage._open`)에 `await ensureAudioReady()`로 완료를 보장한다. 새 진입 경로를 추가한다면 이 규칙을 따를 것.

### 2.7 저장 파일 레이아웃
`<Documents>/saved_audio/[<폴더>/]<videoId>.{m4a,json,jpg}`. 세 확장자가 한 세트로 이동/삭제된다. 다운로드는 `.part`로 받고 완료 후 rename(중단 시 반쪽 파일이 목록에 뜨지 않게). **절대 경로를 사이드카에 저장하지 말 것** — iOS 앱 컨테이너 UUID가 재설치마다 바뀌므로 경로는 매번 재구성한다.

---

## 3. 자주 나오는 증상 → 진단 순서

| 증상 | 먼저 볼 것 |
|---|---|
| 어떤 영상도 저장이 안 됨 / 매니페스트 실패 | 앱 코드보다 라이브러리 의심. `dart run tool/yt_probe.dart` → PROBE_FAIL이면 `youtube_explode_dart` 최신으로 업그레이드(유튜브 변경으로 주기적으로 깨진다). |
| 특정 영상만 "모든 매니페스트 후보 실패 / no playable streams" | 대개 **막 끝난 라이브(post-live DVR)**. `videoDetails.isPostLiveDvr == true`가 신뢰 신호이며 `playabilityStatus.status`는 UNPLAYABLE↔OK로 토글되므로 판단 근거로 쓰면 안 된다. `_diagnoseUnavailable`가 이미 구분해 재시도 안내를 띄운다. 앱 버그 아님. |
| 한국경제Live가 안 나옴 | `dart run tool/wowtv_live_probe.dart` — 3단계 중 어디서 끊겼는지 바로 나온다. `embed=null`이면 한경 페이지 개편(정규식 수정), `hlsManifestUrl 없음`이면 방송 중이 아니거나 유튜브 차단, `PROBE_OK`인데 앱만 안 되면 그때 앱 코드를 본다. |
| 한국어 영상이 영어로 저장/재생됨 | `dart run --define=VID=<videoId> tool/yt_track_probe.dart` (‼️ `--define`은 파일 경로 **앞**에 와야 한다). |
| 잠금화면 길이가 실제의 2배 | androidVr 스트림의 컨테이너 duration이 실제의 2배로 들어오는 결함. `SavedAudioPage._sourceFor`가 `ClippingAudioSource(end: item.duration)`로 보정한다 — 이 보정을 지우면 재발. |
| 저장한 곡을 탭해도 무음 | §2.1의 `btPlaybackOrigin` 규칙 위반을 먼저 의심. |
| 백그라운드(잠금화면·제어센터)에서 정지를 눌렀는데 다시 재생됨 | §2.4.1 위반. `await btPlayer.play()`가 있으면 그 코드는 곡이 끝날 때가 아니라 **정지를 누른 순간** 깨어난다 — `_playWithRetry`의 400ms 재시도가 그 타이밍에 실행돼 재생을 되살렸다. 백그라운드 정지는 앱 화면 토글을 거치지 않아 `btPlayIntent`가 true로 남으므로 그 가드로는 못 막는다. `unawaited`로 고침. |
| 실기기 `flutter run`이 "connecting to vmService"에서 멈춤 | 기기 **설정 → 개인정보 보호 및 보안 → 로컬 네트워크**에서 앱 토글 ON. Info.plist에 Bonjour 키를 수동 추가하지 말 것(Flutter가 디버그 빌드에 자동 주입). `flutter run --release`로 우회 가능. |

모든 런타임 로그는 `[BT] ` 접두어를 쓴다(`_btLog` / `debugPrint`). 새 로그도 이 접두어를 유지할 것 — 콘솔.app 필터가 여기에 걸려 있다.

---

## 4. 명령어

```bash
flutter pub get
flutter analyze                 # 린트: package:flutter_lints
flutter test                    # 현재는 스모크 테스트 1개뿐
flutter run                     # 기본 디버그(iOS 실기기 이슈는 위 표 참고)
flutter run --release           # vmService attach 없이 실기기 확인

dart run tool/yt_probe.dart                              # 추출 라이브러리 생존 확인
dart run --define=VID=<videoId> tool/yt_track_probe.dart  # 오디오 트랙(언어) 확인
dart run tool/wowtv_live_probe.dart                      # 한국경제Live 3단계 확인
```

`tool/`의 스크립트는 flutter 의존 없이 도는 standalone이라 `live_service.dart`의 정규식·요청 형태를 복제해 두었다. 한쪽을 고치면 다른 쪽도 맞출 것.

툴체인: Flutter 3.44.4 stable / Dart 3.12 · Android Gradle 8.12 + AGP 8.9.1 + Kotlin 2.1.0 + Java 17 타겟(Flutter가 Android Studio 내장 JBR 21을 쓰므로 Gradle 7.x는 빌드 불가). Flutter SDK는 `~/work/kwic/flutter/flutter`.

---

## 5. 작업 관례

- **주석은 한국어로, "왜"를 남긴다.** 이 저장소의 주석 대부분은 iOS/유튜브의 비직관적 제약을 설명한다. 이유 없는 코드처럼 보여도 지우기 전에 주석을 읽을 것.
- 상태 플래그(`btPlayIntent`, `btPlaybackOrigin`, `audioReady` …)는 전부 특정 버그의 대응책이다. 리팩터링으로 합치기 전에 어떤 시나리오를 막는지 확인한다.
- 유튜브 DOM에 주입하는 JS는 클래스명 하드코딩을 피하고(기존 메뉴 항목을 복제해 텍스트만 교체), 주입 실패 시 폴백 경로(공유 가로채기)가 살아 있게 둔다.
- `git status`에 빌드 산출물이 섞이지 않게, 커밋은 요청받았을 때만. 브랜치는 `work`, PR 대상은 `main`.
- 자동화된 테스트가 사실상 없다. 변경 검증은 실기기 실행 + `[BT]` 로그 확인이 기본이다.
