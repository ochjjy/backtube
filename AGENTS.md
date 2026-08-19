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
| [lib/main.dart](lib/main.dart) | `main()` + `WebViewPage`. m.youtube.com 웹뷰, 수평 스와이프 뒤로/앞으로, JS 주입(공유 가로채기 / ⋮메뉴에 "오디오로 저장" 항목), 저장 진행·취소 다이얼로그, 봇 확인 우회(`_resolveViaWebView`, §2.3.3). 오디오 재생 코드는 없다. |
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
| [tool/yt_repeat_probe.dart](tool/yt_repeat_probe.dart) | 같은 프로세스에서 저장을 연속 수행해 단계별 소요시간·`requireWatchPage` 영향을 잰다. "준비 중이 길다 / 두 번째부터 안 된다" 진단용. |
| [tool/yt_client_sweep.dart](tool/yt_client_sweep.dart) | InnerTube 클라이언트 11종을 훑어 매니페스트·mp4 오디오·URL 생존을 표로 낸다. 봇 확인에 막혔을 때 "다른 클라이언트로 우회되나"를 판단하는 근거(§2.3.3). |
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

매니페스트는 **`requireWatchPage: true`(패키지 기본값)로 요청한다. 끄지 말 것.**

한 번 껐다가 되돌린 이력이 있다. 끄면 빨라지는 건 사실이다(실측 2026-08-17, `tool/yt_repeat_probe.dart`: ios 매니페스트 1752~2055ms → 877~917ms). watch 페이지는 n/sig 챌린지를 풀 JS 솔버가 있을 때만 쓰이는데 이 앱은 솔버가 없으니 낭비로 보였다. **그런데 끄고 나서 저장이 아예 안 됐다.** watch 페이지를 함께 받으면 player 요청에 그 페이지의 쿠키·visitorData·STS가 실리는데(`video_controller.getPlayerResponse`), 그게 빠지면 유튜브가 세션을 신뢰하지 않아 스트림 URL이 §2.3.2.1의 "첫 1MB만" 제한에 걸리는 것으로 보인다. 1초 아끼려고 저장을 깨뜨릴 일이 아니다.

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

### 2.3.2 매니페스트 성공 ≠ 다운로드 가능 (다운로드는 우리가 직접 한다)
매니페스트가 나와도 그 안의 스트림 URL이 403인 경우가 있다(특히 마지막 폴백 default(ANDROID)). 검증 없이 다운로드에 들어가면 youtube_explode가 **403 → 매니페스트 재조회 → 같은 URL 재시도를 조용히 무한 반복**한다(`YoutubeHttpClient._getStream`의 `while` 루프. 예외도 로그도 나오지 않는다). 실제로 "다운로드 시작 대기 중"에서 영영 멈추는 버그가 났다(2026-08-17).

- **다운로드를 패키지에 맡기지 않는다.** `_rangedDownload`가 직접 range 요청으로 받는다(`yt.videos.streamsClient.get()`은 쓰지 않는다). 실패가 즉시 예외로 드러나고 재시도 횟수도 우리가 정한다. 조각은 1MB이며(§2.3.2.1 — 그보다 크면 403), 끊기면 **받은 지점부터** 같은 조각을 최대 3회 다시 요청한다. 실측(2026-08-18, 청크 1MB로 강제): ANDROID·IOS 양쪽 모두 4조각 바이트 수 정확히 일치.
- `_stallTimeout`(45초): 데이터가 한 조각도 안 오면 끊고 사용자에게 안내한다. 무한 대기 자체를 불가능하게 하는 안전장치.
- **다운로드 403은 URL을 갈아타는 신호다**(`_StreamForbidden`). 재시도해도 같은 403이 반복될 뿐이므로(실측: 4연발) 곧바로 웹뷰 세션 URL(§2.3.3)로 바꿔 한 번 더 받는다. 매니페스트가 성공했다고 해서 스트림 URL이 살아 있는 건 아니다 — 봇 확인이 걸린 기기에서 `manifest[android] OK → 다운로드 403`이 실측됐다.

**URL을 미리 찔러 보는 사전 검증은 두지 않는다.** 예전에 `_streamUrlWorks`가 1KB만 받아 후보를 걸렀는데, ⑴ 판정이 실제 다운로드와 어긋났고(검증 206 → 곧이은 다운로드 403), ⑵ 요청을 한 번 더 보내는 것 자체가 이미 의심받는 IP의 rate limit을 더 건드리며, ⑶ 애초 목적(죽은 URL로 무한 대기 방지)은 다운로더를 직접 구현하면서 사라졌다. **검증은 실제 다운로드가 대신한다.**

### 2.3.2.1 PO token이 없는 URL은 **첫 1MB만** 받아진다 (403의 진짜 원인)
저장이 403으로 죽던 문제의 근본 원인. 유튜브는 PO token(`pot`)이 없는 스트림 URL에 **처음 약 1MB만 주고 그 뒤 range 요청을 전부 403으로 막는다.** 실측(2026-08-18):

| 요청 | 결과 |
|---|---|
| `bytes=0-1048575` (첫 1MB) | 206 |
| `bytes=0-1199999` (1.2MB) | **403** |
| `bytes=7340032-8388607` (중간 1MB) | **403** |
| 1MB씩 순차 → 2번째 조각 | **403** |

**어느 클라이언트로 받은 URL이냐가 갈림길이다.** 클라이언트 13종을 "2번째 1MB 조각까지 받아지는가"로 검사한 결과(2026-08-18, 실패 영상 kH-it8YaWls). 1KB 검증은 전부 통과하므로 **반드시 2번째 조각까지 봐야 한다**:

| 클라이언트 | 결과 |
|---|---|
| **ANDROID_VR** | PO token 없이 **전체 다운로드 가능한 유일한 클라이언트**. 단 영상에 따라 `LOGIN_REQUIRED`가 나며, 그런 영상은 토큰 없이는 방법이 없다. 앱 밖(Dart)에서는 막혀도 **웹뷰 안에서 부르면 통과하는 경우가 있다**(실기기 2026-08-18: `it_ANDROID_VR=2개` → 완주). 그래서 in-page 시도 목록의 첫 번째다 |
| ANDROID / IOS | 오디오는 나오지만 1조각 200 → **2조각 403, 20MB지점 403** |
| ANDROID_MUSIC·ANDROID_CREATOR·IOS_MUSIC·IOS_CREATOR·TVHTML5 | `LOGIN_REQUIRED` |
| MWEB / WEB | `UNPLAYABLE` |
| WEB_EMBEDDED / TV_EMBEDDED | `ERROR` |

즉 **ANDROID_VR이 `LOGIN_REQUIRED`를 내는 영상은 로그인 없이는 방법이 없다.** URL 서명(`sparams`)에 `range`가 없어 재-range 자체는 허용되고, `alr=yes`나 range 전달 방식(헤더/쿼리) 변경으로도 뚫리지 않는다 — 순수하게 PO token 게이팅이다.

그래서 웹뷰의 in-page InnerTube 시도 목록은 **ANDROID_VR이 첫 번째**다(웹뷰 세션에서 나가므로 로그인 상태면 쿠키가 그대로 실린다).

**로그인 없이 푸는 길은 PO token 수확이다.** 이 영상은 `hlsManifestUrl`도 `dashManifestUrl`도 없고 `serverAbrStreamingUrl`(SABR)만 있다 — 즉 유튜브가 PO token을 전제로 전달한다. 그런데 그 토큰은 **로그인과 무관하게 페이지의 BotGuard가 만든다**. 웹 플레이어가 로그인 없이 102분짜리를 재생한다는 것이 그 증거다. 그래서 `_injectPlayerCapture`는 Resource Timing에서 `pot=`가 실린 googlevideo 요청을 찾아 토큰을 `window.__btAuth`에 담고, `_resolveViaWebView`는 그것을 ⑴ 우리 InnerTube 요청 본문(`serviceIntegrityDimensions.poToken`)과 ⑵ 응답으로 받은 스트림 URL(`&pot=`) 양쪽에 붙인다. 토큰은 세션(visitorData)에 묶이므로 **반드시 페이지의 visitorData와 짝지어** 보내야 한다.

**재생 없이 토큰을 얻으려던 시도는 모두 실패했고 코드에서 제거했다.** 기록만 남긴다:

| 시도 | 결과 |
|---|---|
| 토큰을 `localStorage`에 보존해 재사용 | 애초에 토큰을 한 번도 못 얻어 의미 없었다 |
| 숨은 iframe(watch 페이지는 `SAMEORIGIN`이라 프레이밍 가능) | 메인 웹뷰는 자동재생이 막혀 있어 재생이 시작되지 않음 |
| 자동재생 허용 전용 숨은 웹뷰(`mediaTypesRequiringUserAction: {}`) | 재생은 됐지만(`video=playing:17`) **iOS는 인라인 재생이 기본이 아니라 전체화면으로 떠 버렸다**(`allowsInlineMediaPlayback` 미설정). 게다가 앱 시작과 동시에 웹뷰 두 개를 띄우면 메인 페이지가 검은 화면이 된다 |
| 제3 프론트엔드(Piped 4곳 · Invidious 3곳) | 전부 HTTP 401/403/500/502 — 공개 인스턴스가 죽었거나 차단됨 |

되살릴 거라면 `allowsInlineMediaPlayback: true`가 필수이고, 그래도 SABR 영상에서는 토큰을 얻지 못한다(§2.3.2.2).

### 2.3.2.3 SABR 적용 범위가 넓어지고 있다 (2026-08-19 관측)
**같은 영상이 며칠 사이에 되던 것에서 안 되는 것으로 바뀐다.** 2026-08-18에 `androidVr`로 완주했던 영상들이 2026-08-19에는 같은 클라이언트에서 `LOGIN_REQUIRED`가 됐다:

| videoId | 8/18 | 8/19 |
|---|---|---|
| `rtkzDogYxUU` (14.8MB, 완주 성공) | androidVr OK | **`LOGIN_REQUIRED`** |
| `7cPsxE841Yc` (1.5MB, 완주 성공) | androidVr OK | **`LOGIN_REQUIRED`** |
| `dQw4w9WgXcQ` (오래된 인기 영상) | OK | **OK, 2조각도 200** |

즉 ⑴ 제한은 IP가 아니라 **영상마다** 걸리고(같은 시각 같은 회선에서 `dQw4w9WgXcQ`는 android/androidVr 모두 정상, 1MB 너머도 받아진다), ⑵ 대상 영상이 **시간이 지나며 늘고 있다**. 최근 업로드된 뉴스/시사 영상이 먼저 걸리는 경향으로 보인다.

**그래서 "어제는 됐는데 오늘은 안 된다"는 앱 회귀가 아니다.** 코드를 의심하기 전에 `dQw4w9WgXcQ` 같은 대조군 영상으로 한 번 확인할 것 — 그게 되면 앱은 정상이고 해당 영상이 새로 걸린 것이다.

### 2.3.2.4 itag 18(합본)은 PO token 없이도 끝까지 받아진다 — 현재의 해법
yt-dlp 쪽 자료(이슈 #17348, PO Token Guide)에서 **"토큰이 없으면 format 18만 남는다"**는 서술을 보고 실측한 결과, **이것이 유일하게 살아 있는 경로다.**

itag 18 = 360p H.264 + AAC-LC가 하나로 합쳐진(muxed/progressive) mp4. 실측(2026-08-19, 오디오 전용이 전부 1MB에서 막히던 영상들):

| 영상 | itag18 크기 | 통짜 다운로드(`Range: bytes=0-`) |
|---|---|---|
| VOA 뉴스 15분 | 12.7MB | ✅ 바이트 일치 |
| 시사 **108분** | 264MB | ✅ 바이트 일치(84초) |
| 뉴스 2분 | 3.8MB | ✅ |

- **1MB 제한이 없다.** 마지막 조각까지 200이 나온다.
- 컨테이너는 `ftypmp42`, 코덱은 `avc1.42001E, mp4a.40.2` — AAC라 iOS AVPlayer가 그대로 재생한다(§2.2). 저장 확장자는 `.m4a` 그대로 두어도 문제없다.
- `contentLength`를 안 주는 영상이 있다 → `total=0`으로 열린 range(`0-`)를 쓰면 전체가 받아진다.
- 대가는 **용량**이다. 영상이 섞여 있어 오디오 전용보다 크다(짧은 뉴스는 비슷하거나 오히려 작고, 긴 영상은 2~3배). 오디오 품질도 `AUDIO_QUALITY_LOW`(AAC 약 96kbps)로 itag 140(128kbps)보다 낮다. 말소리 위주 콘텐츠에는 충분하다.

**현재는 `_preferMuxed = true`라 합본을 맨 먼저 받는다.** 저장 대상 영상 대부분이 오디오 전용에서 막히는 상황이라, 후보를 훑느라 1MB씩 헛되이 받고 10초 이상 쓰는 것보다 바로 합본으로 가는 편이 빠르고 확실하기 때문이다. 이때 매니페스트 해석(`_resolveAudioStream`)도 통째로 건너뛴다 — 그래서 전부 실패했을 때의 사유 진단(`_diagnoseUnavailable`)을 다운로드 루프 끝에서 따로 부른다.

유튜브가 토큰 요구를 거둬들이면 `_preferMuxed = false`로 되돌린다. 그러면 오디오 전용이 우선이고 합본은 다시 맨 마지막 보루가 된다.

**음질 실측(2026-08-19, ffprobe)**: 합본의 오디오 트랙은 AAC-LC 44.1kHz 스테레오 **96~128kbps**(영상마다 다름), 오디오 전용 itag140은 132kbps. 코덱·샘플레이트·채널은 같다. itag 22(720p/192k AAC)는 **어떤 클라이언트에도 제공되지 않아** 합본 음질을 더 올릴 방법은 없다. 오디오 전용 쪽도 이미 최선을 고르고 있다(opus 251이 150k로 더 높지만 iOS AVPlayer가 재생 못 한다 — §2.2). `cappedClients`(§2.3.2.2)에 ANDROID가 들어 있어도 **itag 18은 건너뛰지 않는다** — 토큰을 요구하는 것은 오디오 전용 포맷뿐이다.

### 2.3.3 봇 확인("로그인하여 봇이 아님을 확인하세요") 우회는 웹뷰 세션이다
유튜브가 봇 확인을 걸면 앱이 Dart에서 보내는 InnerTube 요청은 **어떤 클라이언트로도** 뚫리지 않는다. 실측(2026-08-17, `tool/yt_client_sweep.dart`): 패키지가 주는 11종 중 매니페스트가 나오는 것은 ios·androidVr·android·androidSdkless 넷뿐이고, 나머지(safari/mweb/tv/tvSimplyEmbedded/webCreator/mediaConnect/androidMusic)는 **봇 확인이 걸리지 않은 IP에서도** 전부 실패한다(유튜브가 인증을 요구하도록 바꿨고, 패키지도 셋을 `@Deprecated`로 표시했다). 클라이언트를 더 추가하는 건 우회책이 아니다.

대신 앱에는 **이미 봇 확인을 통과한 세션**이 있다 — 사용자가 유튜브를 보던 웹뷰다. `main.dart`의 `_resolveViaWebView`가 그 안에서 스트림 URL을 받아 오고(같은 출처라 쿠키·visitorData가 자동으로 실린다 — 앱이 쿠키를 직접 다루지 않는다), 다운로드만 앱이 한다. 어느 경로든 **`url` 필드가 있는 포맷만** 고른다(`signatureCipher`는 JS 솔버 없이 못 푼다).

해석 순서(앞이 성공하면 뒤는 시도하지 않는다):
0. **`MEDIA-PLAYED-<itag>` / `MEDIA-<itag>` — 플레이어가 재생에 쓰던 미디어 URL.**
   **사용자가 그 영상을 직접 재생한 뒤 저장하는 흐름을 위해 이 후보를 우리가 만든 InnerTube URL보다 먼저 쓴다.** 토큰(`pot`)이 붙어 있으면 최우선(`MEDIA-*`), 토큰이 안 보여도 실제 재생 세션에서 나온 URL이라 성질이 다를 수 있으므로 InnerTube 후보 **앞에서** 한 번 시도한다(`MEDIA-PLAYED-*`). 다운로드 쪽에서도 1MB 제한이 확인된 뒤라도 `MEDIA*` 후보만은 건너뛰지 않는다(`fromPlayback`). 가장 확실하다. `_injectPlayerCapture`가 **Resource Timing**(`performance.getEntriesByType('resource')`)·fetch/XHR·`<video>` 엘리먼트 세 곳에서 `googlevideo.com/videoplayback` URL을 주워 videoId·itag별로 모아 둔다. **Resource Timing이 핵심이다** — 실측(2026-08-18) `video=blob:`(MSE 재생 중)인데도 fetch/XHR 훅에는 아무것도 안 걸렸다. 유튜브가 워커나 미디어 엔진을 통해 요청을 내보내면 JS 훅을 우회하지만, Resource Timing에는 URL이 남는다(버퍼가 넘치지 않게 `setResourceTimingBufferSize(1000)`으로 키우고 2초마다 훑는다)(요청마다 달라지는 `range`/`rn`/`rbuf`/`sq` 등은 떼고 보관). **이미 재생되고 있는 URL이라 서명·`n`·PO token이 전부 유효**하므로 1MB 제한에 걸리지 않는다. player 응답을 뜯는 아래 경로들과 달리 서명 해독도 필요 없다. 오디오 itag 우선순위는 140 → 141 → 139. `clen`·`dur` 파라미터에서 크기와 길이도 함께 얻는다. 피드에서 인라인 재생하면 주소에 `v=`가 없어 videoId를 알 수 없는데, 그때는 `_last`에 담아 두고 **`clen`이 기대 크기와 정확히 일치할 때만** 쓴다(다른 영상 오디오를 저장하는 사고 방지). 기대 크기는 Dart가 매니페스트에서 얻어 `expectSize`로 넘긴다.
1. `PAGE-CAPTURED` — `_injectPlayerCapture`가 가로챈 **페이지 자신의** player 응답(§2.3.2.1). 토큰이 붙어 있어 가장 좋다.
2. `ytInitialPlayerResponse` — 지금 웹뷰가 열고 있는 watch 페이지의 초기 응답.
3. `WATCH-HTML` — **웹뷰 세션으로 `/watch?v=<id>` HTML을 직접 fetch** 해 그 안의 `ytInitialPlayerResponse`를 중괄호 균형으로 잘라 쓴다. 사용자가 **피드 목록의 ⋮에서 바로 저장**하면 1·2가 비는데(그 영상의 watch 페이지를 연 적이 없다) 이 경로가 그때를 메운다.
4. 우리가 만든 InnerTube 요청(ANDROID → IOS → 페이지 컨텍스트). 토큰이 없어 1MB 제한에 걸리므로 최후 수단이다.

**페이지의 PO token을 훔쳐 쓴다.** 1MB 제한을 푸는 열쇠는 `pot`인데, 그 토큰은 페이지가 BotGuard로 만들어 **자기 player 요청 본문**(`serviceIntegrityDimensions.poToken`)에 실어 보낸다. 그래서 `_injectPlayerCapture`는 응답뿐 아니라 **요청 본문**도 가로채 토큰과 그것에 묶인 `visitorData`를 `window.__btAuth`에 담아 둔다. 우리가 만드는 InnerTube 요청은 그 둘을 그대로 실어 보낸다(토큰과 visitorData는 반드시 짝이 맞아야 한다).

**진단이 로그에 남는다.** 웹뷰 해석은 실패해도 성공해도 `[pot=O/X media=… cap=… ipr=… html=… video=…]`를 함께 남긴다. 각 경로에 오디오 포맷이 몇 개 있었고 그중 **평문 URL이 몇 개/암호화(signatureCipher)가 몇 개**인지까지 센다. 이게 없던 동안 "왜 이 경로가 안 쓰였나"를 계속 추측해야 했다. `video=blob:`이면 MSE 재생(JS가 세그먼트를 받으므로 미디어 URL 가로채기가 가능), `video=https://`면 네이티브 재생(JS 훅에 안 걸린다)이라는 뜻이다.

**모바일 watch 페이지의 `ytInitialPlayerResponse`는 대개 `signatureCipher`만 담고 평문 `url`이 없다**(실기기 실측 2026-08-18: `WATCH-HTML`이 걸리지 않고 4번으로 떨어졌다). 그래서 2·3번은 자주 비고, 실질적인 해답은 0번이다 — **사용자가 그 영상을 웹뷰에서 재생해야 잡힌다.**

이 경로는 `AudioUnavailableException.botBlocked`일 때만 탄다. 다른 사유(비공개·처리 중)는 세션을 바꿔도 결과가 같다.

다운로드가 403이면 후보를 바꿔 가며 계속한다: 매니페스트 → 직접 androidVr → 직접 ios → 웹뷰 세션 → 마지막으로 **다운로드까지 웹뷰 안에서**(`_downloadChunkViaWebView`, 조각을 base64로 채널에 실어 보낸다). ⑶이 가능한 것은 googlevideo가 웹뷰 출처에 CORS를 열어 두기 때문이다 — 실측(2026-08-18): `access-control-allow-origin: https://m.youtube.com`, `allow-credentials: true`, preflight가 `Range` 헤더 허용.

**직접 받는 URL에는 range를 반드시 지정한다.** 그냥 GET 하면 유튜브가 재생 속도로 스로틀링한다 — 실측(2026-08-18, 3.4MB): range 없음 **102초** vs range 지정 **0.9초**. 110배다. `_rangedDownload`가 이 처리를 하고 있으니 지우지 말 것.

### 2.3.4 메타 조회 실패가 저장을 막으면 안 된다
`yt.videos.get()`은 **watch 페이지를 긁는** 요청이라 유튜브의 rate limit(`RequestLimitExceededException`, `GET /watch?v=…`)에 **가장 먼저** 걸린다. 실측(2026-08-18): 매니페스트는 멀쩡한데 이 요청만 429가 나서 저장 전체가 실패했다. 제목·썸네일은 저장의 필수 요소가 아니므로 `videoFuture`는 `catchError`로 null이 되게 두고 저장을 계속한다. **다시 `Future.wait`로 묶지 말 것** — 메타 실패가 저장을 죽인다.

그래서 **저장 경로에서 `videos.get()`을 아예 부르지 않는다.** 지우고 나면 필요한 메타는 전부 더 싼 출처에 있다:

| 항목 | 출처 | 비용 |
|---|---|---|
| 제목·저자 | 웹뷰 우회 응답의 `videoDetails`(있으면) → oEmbed(`/oembed?url=…&format=json`) | 가벼운 공개 API 1회 |
| 길이 | **스트림 URL의 `dur` 파라미터** (`_durationFromUrl`) | 요청 0회 |
| 썸네일 | `https://i.ytimg.com/vi/<id>/hqdefault.jpg` 고정 규칙 | 이미지 1회 |

실측(2026-08-18): `dur=322.803` ↔ 실제 323초, oEmbed는 한국어 제목·채널명을 정확히 준다.

메타는 **다운로드가 끝난 뒤에** 채운다. 순서가 중요하다 — 먼저 하면 그 요청들이 rate limit을 건드려 정작 스트림을 못 받는다.

### 2.4 오디오 언어는 `hl`로 고른다
내장 `YoutubeApiClient`는 `hl:'en'`이 하드코딩돼 있어, 자동 더빙 영상이 **영어 더빙 트랙을 default로** 내려준다. 스트림을 가져오는 모든 경로는 `withAudioLanguage(client)`(hl=ko)를 거치고, 매니페스트는 `preferDefaultAudioTrack()`으로 걸러야 한다(비트레이트 정렬만 하면 더빙 트랙이 더 높아 오염된다). `gl`(지역)은 지역제한 영상을 깨뜨리므로 건드리지 않는다.

### 2.4.1 `btPlayer.play()`를 await 하지 말 것
just_audio의 `play()`가 돌려주는 Future는 **재생이 시작될 때가 아니라 재생이 끝나거나 일시정지/정지될 때** 완료된다(패키지 문서에 명시). 라이브처럼 끝나지 않는 소스에서 `await btPlayer.play()`를 하면 호출한 함수가 영영 반환되지 않는다 — 실제로 "라이브 연결 중" 팝업이 안 닫히고 `LiveSession._busy`가 풀리지 않아 만료 갱신까지 멈추는 버그가 났다. 재생 시작만 필요하면 `unawaited(btPlayer.play())`를 쓰고, 시작 여부는 `playerStateStream`으로 확인한다.

### 2.5 오디오 세션 활성화 타이밍
[ios/Runner/AppDelegate.swift](ios/Runner/AppDelegate.swift)는 카테고리(`.playback`)만 설정하고 **`setActive`는 하지 않는다**. 앱 실행만으로 다른 앱 음악을 끊지 않기 위함이며, 활성화(`session.setActive(true)`)는 Dart 쪽에서 **재생 직전에** 한다(`SavedAudioPage._play`/`_playFrom`/`_startPlayAll`). 세션이 죽은 상태로 로드하면 iOS에서 `-11800/-11819`로 실패한다.

백그라운드 재생 자체는 `UIBackgroundModes: audio`(iOS)와 `AudioService` 포그라운드 서비스(Android)가 담당한다 — 이미 재생 중인 오디오는 백그라운드로 가도 이어진다.

### 2.5.1 인터럽션 처리는 필수다 (문자 한 통에 재생이 죽는다)
알림음·전화가 오면 iOS가 오디오 세션을 끊는다. 앱이 아무것도 하지 않으면 인터럽트가 끝나도 세션이 되살아나지 않아 **그대로 무음**이 된다(실제로 "문자 받고 소리가 안 난다"는 버그가 났다). `player_service.dart`의 `_attachInterruptionHandling`이 `session.interruptionEventStream`을 구독해 처리한다:

| 이벤트 | 처리 |
|---|---|
| `duck` | 건드리지 않는다(iOS가 볼륨만 줄인다) |
| `pause`/`unknown` 시작 | 재생 중이었으면 멈추고 `_resumeAfterInterruption` 표시 |
| `pause` 종료 | `btPlayIntent`가 살아 있으면 **세션 재활성화 후** 재생 재개 |
| `unknown` 종료 | 자동 재개하지 않는다 — 다른 앱이 오디오를 가져간 경우라 되살리면 남의 재생을 끊는다 |

두 가지를 지킬 것: ⑴ 인터럽트로 인한 정지에 **`btPlayIntent`를 false로 바꾸지 않는다**(사용자가 누른 정지가 아니다 — §2.1). 그래서 별도 플래그를 쓴다. ⑵ 재개 전에 `session.setActive(true)`를 반드시 부른다. 인터럽트 뒤 세션은 비활성이라 그냥 `play()`하면 `-11800/-11819`로 실패한다(§2.5).

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
| 저장이 "준비 중"에서 오래 걸림 | 팝업의 단계 표시(영상 정보 → 스트림 찾는 중(ios/androidVr/default) → 스트림 확인 중 → 다운로드 시작 대기)와 `[BT] download.t:` 로그로 어느 단계인지 특정한다. 후보 하나가 실패하면 30초 타임아웃 → 다음 후보라, 최악의 경우 3×30초+진단 15초가 통째로 "준비 중"으로 보인다. `dart run tool/yt_repeat_probe.dart`로 라이브러리/유튜브 쪽인지 앱 쪽인지 가른다. |
| 저장이 403으로 실패 | `from=0`이면 URL/세션 문제, **`from>0`이면 PO token 문제**(§2.3.2.1 — 첫 1MB만 받아진다). 후자는 `via=PAGE-CAPTURED` 응답을 못 쓴 것이므로, 웹뷰에서 그 영상을 재생해 페이지가 player 요청을 하게 만든 뒤 다시 저장하면 된다. `_chunkSize`가 1MB보다 커졌는지도 확인. |
| 저장이 "다운로드 시작 대기 중"에서 영영 멈춤 | **매니페스트는 성공했는데 스트림 URL이 403인 경우.** youtube_explode는 이때 매니페스트 재조회 → 같은 URL 재시도를 로그도 예외도 없이 무한 반복한다(`YoutubeHttpClient._getStream`의 `while`). §2.8의 두 방어선(`_streamUrlWorks` 사전 검증, `_stallTimeout`)이 이미 막고 있으니, 다시 나타나면 그 둘이 지워졌는지부터 확인할 것. 어느 클라이언트의 URL이 죽었는지는 `dart run --define=VID=<videoId> tool/yt_repeat_probe.dart` 첫 섹션에 나온다. |
| `RequestLimitExceededException: rate limiting` | 요청 URL을 볼 것. `GET /watch?v=…`이면 메타 조회(`videos.get`)가 막힌 것이고 **저장은 계속돼야 정상이다**(§2.3.4). 저장까지 실패했다면 메타 실패가 다시 치명적으로 취급되고 있는지 확인. 매니페스트 요청이 막힌 것이면 §2.3.3의 웹뷰 우회가 자동으로 돈다. |
| "로그인하여 봇이 아님을 확인하세요" | 유튜브의 봇 확인(§2.3.3). 앱은 후보를 모두 시도한 뒤 웹뷰 세션 우회(`_resolveViaWebView`)를 한 번 더 타고, 그것도 실패하면 안내 팝업을 띄운다. 로그에서 `webview resolve 성공/실패`를 먼저 볼 것. 실패가 `no-audio`면 세 컨텍스트 모두 평문 `url`을 못 받은 것(웹뷰가 로그인/봇 확인 화면에 걸려 있을 수 있으니 웹뷰에서 영상이 실제로 재생되는지 확인). 봇 확인 자체는 IP 평판에 걸리므로 셀룰러↔Wi-Fi 전환도 유효한 확인 수단이다. |
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
dart run tool/yt_repeat_probe.dart                       # 연속 저장 재현 + 단계별 소요시간
dart run --define=VID=<videoId> tool/yt_client_sweep.dart # 클라이언트 11종 전수 확인

tool/deploy_ios.sh              # 아이폰에 빌드+설치+실행 (기기 자동 탐지, [BT] 로그 표시)
tool/deploy_ios.sh --install    # 빌드+설치만
tool/deploy_ios.sh --logs       # 이미 깔린 앱의 로그만
tool/deploy_ios.sh --clean      # flutter clean 후 처음부터
```

`deploy_ios.sh`는 **릴리즈로** 올린다. 실기기 디버그 실행이 "connecting to vmService"에서 멈추는 문제(§3)를 피하기 위함이고, 릴리즈에서도 `debugPrint`는 그대로 나오므로 `[BT]` 로그는 다 보인다.

`tool/`의 스크립트는 flutter 의존 없이 도는 standalone이라 `live_service.dart`의 정규식·요청 형태를 복제해 두었다. 한쪽을 고치면 다른 쪽도 맞출 것.

툴체인: Flutter 3.44.4 stable / Dart 3.12 · Android Gradle 8.12 + AGP 8.9.1 + Kotlin 2.1.0 + Java 17 타겟(Flutter가 Android Studio 내장 JBR 21을 쓰므로 Gradle 7.x는 빌드 불가). Flutter SDK는 `~/work/kwic/flutter/flutter`.

---

## 5. 작업 관례

- **주석은 한국어로, "왜"를 남긴다.** 이 저장소의 주석 대부분은 iOS/유튜브의 비직관적 제약을 설명한다. 이유 없는 코드처럼 보여도 지우기 전에 주석을 읽을 것.
- 상태 플래그(`btPlayIntent`, `btPlaybackOrigin`, `audioReady` …)는 전부 특정 버그의 대응책이다. 리팩터링으로 합치기 전에 어떤 시나리오를 막는지 확인한다.
- 유튜브 DOM에 주입하는 JS는 클래스명 하드코딩을 피하고(기존 메뉴 항목을 복제해 텍스트만 교체), 주입 실패 시 폴백 경로(공유 가로채기)가 살아 있게 둔다.
- `git status`에 빌드 산출물이 섞이지 않게, 커밋은 요청받았을 때만. 브랜치는 `work`, PR 대상은 `main`.
- 자동화된 테스트가 사실상 없다. 변경 검증은 실기기 실행 + `[BT]` 로그 확인이 기본이다.
