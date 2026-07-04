import UIKit
import Flutter
import AVFoundation

@main
@objc class AppDelegate: FlutterAppDelegate {
  private var bgTask: UIBackgroundTaskIdentifier = .invalid

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

    // 백그라운드 진입 직후 오디오가 아직 재생 전이면 iOS가 앱을 바로
    // suspend시켜 스트림 로딩/재생 시작이 죽는다. beginBackgroundTask로
    // ~30초의 유예를 얻어 로딩을 끝내고 재생을 시작할 시간을 확보한다.
    // (재생이 시작되면 UIBackgroundModes audio가 이어받는다.)
    if let controller = window?.rootViewController as? FlutterViewController {
      let channel = FlutterMethodChannel(
        name: "backtube/lifecycle",
        binaryMessenger: controller.binaryMessenger
      )
      channel.setMethodCallHandler { [weak self] call, result in
        guard let self = self else {
          result(nil)
          return
        }
        switch call.method {
        case "beginBackgroundTask":
          self.endBgTask()
          self.bgTask = UIApplication.shared.beginBackgroundTask(
            withName: "backtube-audio-start"
          ) { [weak self] in
            self?.endBgTask()
          }
          result(nil)
        case "endBackgroundTask":
          self.endBgTask()
          result(nil)
        default:
          result(FlutterMethodNotImplemented)
        }
      }
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  private func endBgTask() {
    if bgTask != .invalid {
      UIApplication.shared.endBackgroundTask(bgTask)
      bgTask = .invalid
    }
  }
}
