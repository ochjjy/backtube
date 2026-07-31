import 'dart:convert';

import 'package:youtube_explode_dart/youtube_explode_dart.dart';

/// 자동 더빙(auto-dubbing) 영상에서 오디오 언어 선택을 바로잡기 위한 헬퍼.
///
/// youtube_explode의 내장 클라이언트(ios/androidVr/…)는 모두 컨텍스트에
/// `hl:'en'`, `gl:'US'`가 하드코딩돼 있고 HTTP 계층도 `accept-language: en-US`를
/// 보낸다. 그래서 한국어 원본 뉴스처럼 YouTube가 자동 더빙 트랙을 제공하는
/// 영상은, YouTube가 요청 UI 언어(en)에 맞춰 "영어 더빙" 트랙을 default 오디오로
/// 내려준다. 이 단일 트랙을 그대로 저장·재생하면 한국어 영상이 영어로 저장된다.
///
/// 해결: 클라이언트의 `hl`을 한국어로 덮어 YouTube가 한국어(원본) 오디오를
/// 내려주게 한다. 지역 제한이 걸린 영상까지 깨지지 않도록 `gl`(지역)은 건드리지
/// 않고 언어(`hl`)와 accept-language만 바꾼다. (yt-dlp의 `lang=` 옵션과 동일 개념)
const String kPreferredAudioLanguage = 'ko';

/// [base] 클라이언트의 payload를 깊은 복사해 `context.client.hl`만 [language]로
/// 바꾼 사본을 만든다. accept-language 헤더도 함께 지정하되 영어를 fallback으로
/// 남겨, 언어별 리소스가 없을 때의 가용성은 유지한다.
YoutubeApiClient withAudioLanguage(
  YoutubeApiClient base, [
  String language = kPreferredAudioLanguage,
]) {
  // payload는 중첩 Map이라 얕은 복사로는 원본 상수를 오염시킨다 → JSON 왕복 복사.
  final payload = json.decode(json.encode(base.payload)) as Map<String, dynamic>;
  final client = payload['context']?['client'];
  if (client is Map) {
    client['hl'] = language;
  }
  return YoutubeApiClient(
    payload,
    base.apiUrl,
    headers: {
      ...base.headers,
      'accept-language': '$language,en;q=0.5',
    },
  );
}

/// 매니페스트가 여러 언어의 오디오 트랙을 함께 담고 있을 때, 원하는(원본/기본)
/// 트랙만 남긴다. 트랙 메타데이터가 하나라도 default로 표시돼 있으면 default와
/// 트랙 정보 없는(단일 트랙) 스트림만 남기고, 그런 표시가 전혀 없으면 원본을
/// 그대로 반환한다. (클라이언트가 단일 트랙만 주는 경우엔 사실상 통과된다.)
Iterable<T> preferDefaultAudioTrack<T extends AudioStreamInfo>(
  Iterable<T> streams,
) {
  final list = streams.toList();
  final hasDefault = list.any((s) => s.audioTrack?.audioIsDefault ?? false);
  if (!hasDefault) return list;
  return list.where(
    (s) => s.audioTrack == null || s.audioTrack!.audioIsDefault,
  );
}
