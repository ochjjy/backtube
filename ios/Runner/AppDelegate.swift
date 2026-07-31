import UIKit
import Flutter
import AVFoundation

@main
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    // 백그라운드 오디오용 카테고리만 미리 지정한다.
    // setActive(true)를 앱 시작 시점에 호출하면 앱을 여는 순간
    // 다른 앱의 음악이 끊기므로, 세션 활성화는 실제 재생 직전에
    // Dart(audio_session/just_audio) 쪽에서 수행한다.
    do {
      try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
    } catch {
      print("AVAudioSession 설정 실패: \(error)")
    }

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}
