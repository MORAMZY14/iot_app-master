import AVFoundation
import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, AVSpeechSynthesizerDelegate {
  private let localSpeechSynthesizer = AVSpeechSynthesizer()
  private var pendingSpeechResult: FlutterResult?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    if let registrar = registrar(forPlugin: "SmartHomeNavigation") {
      registrar.register(SmartHomeTabBarFactory(messenger: registrar.messenger()),
                         withId: "smarthome/system_tab_bar")
      let capabilities = FlutterMethodChannel(name: "smarthome/navigation",
                                               binaryMessenger: registrar.messenger())
      capabilities.setMethodCallHandler { call, result in
        guard call.method == "supportsLiquidGlass" else {
          result(FlutterMethodNotImplemented)
          return
        }
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) { result(true) } else { result(false) }
        #else
        result(false)
        #endif
      }
    }
    let launched = super.application(
      application,
      didFinishLaunchingWithOptions: launchOptions
    )

    localSpeechSynthesizer.delegate = self
    if let controller = window?.rootViewController as? FlutterViewController {
      let channel = FlutterMethodChannel(
        name: "smarthome/local_speech",
        binaryMessenger: controller.binaryMessenger
      )
      channel.setMethodCallHandler { [weak self] call, result in
        guard call.method == "speak" else {
          result(FlutterMethodNotImplemented)
          return
        }
        guard
          let arguments = call.arguments as? [String: Any],
          let text = arguments["text"] as? String,
          !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
          result(
            FlutterError(
              code: "invalid_speech_text",
              message: "Local speech text is empty.",
              details: nil
            )
          )
          return
        }
        let language = arguments["language"] as? String ?? "en-US"
        self?.speakLocally(text: text, language: language, result: result)
      }
    }
    return launched
  }

  private func speakLocally(
    text: String,
    language: String,
    result: @escaping FlutterResult
  ) {
    DispatchQueue.main.async { [weak self] in
      guard let self = self else {
        result(
          FlutterError(
            code: "speech_unavailable",
            message: "The local speech engine is unavailable.",
            details: nil
          )
        )
        return
      }

      do {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
          .playback,
          mode: .voicePrompt,
          options: [.duckOthers, .interruptSpokenAudioAndMixWithOthers]
        )
        try session.setActive(true)

        if self.localSpeechSynthesizer.isSpeaking {
          self.localSpeechSynthesizer.stopSpeaking(at: .immediate)
        }
        self.pendingSpeechResult = result

        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: language)
          ?? AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = language.lowercased().hasPrefix("ar") ? 0.42 : 0.46
        utterance.pitchMultiplier = 1.0
        utterance.volume = 1.0
        self.localSpeechSynthesizer.speak(utterance)
      } catch {
        result(
          FlutterError(
            code: "speech_session_failed",
            message: "Could not start the iPhone playback session.",
            details: error.localizedDescription
          )
        )
      }
    }
  }

  func speechSynthesizer(
    _ synthesizer: AVSpeechSynthesizer,
    didFinish utterance: AVSpeechUtterance
  ) {
    finishLocalSpeech(success: true)
  }

  func speechSynthesizer(
    _ synthesizer: AVSpeechSynthesizer,
    didCancel utterance: AVSpeechUtterance
  ) {
    finishLocalSpeech(success: false)
  }

  private func finishLocalSpeech(success: Bool) {
    let result = pendingSpeechResult
    pendingSpeechResult = nil
    try? AVAudioSession.sharedInstance().setActive(
      false,
      options: .notifyOthersOnDeactivation
    )
    result?(success)
  }
}

private final class SmartHomeTabBarFactory: NSObject, FlutterPlatformViewFactory {
  private let messenger: FlutterBinaryMessenger
  init(messenger: FlutterBinaryMessenger) { self.messenger = messenger; super.init() }
  func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
    FlutterStandardMessageCodec.sharedInstance()
  }
  func create(withFrame frame: CGRect, viewIdentifier viewId: Int64,
              arguments args: Any?) -> FlutterPlatformView {
    SmartHomeTabBar(frame: frame, id: viewId, messenger: messenger,
                   state: args as? [String: Any] ?? [:])
  }
}

private final class SmartHomeTabBar: NSObject, FlutterPlatformView, UITabBarDelegate {
  private let bar: UITabBar
  private let channel: FlutterMethodChannel
  init(frame: CGRect, id: Int64, messenger: FlutterBinaryMessenger,
       state: [String: Any]) {
    bar = UITabBar(frame: frame)
    channel = FlutterMethodChannel(name: "smarthome/system_tab_bar/\(id)", binaryMessenger: messenger)
    super.init()
    // UIKit owns glass, selection, accessibility and SF Symbols. No custom
    // appearance or background image is applied over the system material.
    let definitions = [("Home", "house", "house.fill"),
                       ("Energy", "chart.bar", "chart.bar.fill"),
                       ("Alerts", "bell", "bell.fill"),
                       ("Settings", "gearshape", "gearshape.fill")]
    bar.items = definitions.enumerated().map { index, definition in
      let item = UITabBarItem(title: definition.0, image: UIImage(systemName: definition.1),
                             selectedImage: UIImage(systemName: definition.2))
      item.tag = index
      item.accessibilityIdentifier = "home-tab-\(index)"
      return item
    }
    bar.delegate = self
    update(state)
    channel.setMethodCallHandler { [weak self] call, result in
      guard call.method == "update", let state = call.arguments as? [String: Any] else {
        result(FlutterMethodNotImplemented)
        return
      }
      self?.update(state)
      result(nil)
    }
  }
  private func update(_ state: [String: Any]) {
    let index = state["index"] as? Int ?? 0
    if let items = bar.items, items.indices.contains(index) {
      bar.selectedItem = items[index]
      let count = state["unreadCount"] as? Int ?? 0
      items[2].badgeValue = count > 0 ? (count > 99 ? "99+" : String(count)) : nil
    }
    bar.overrideUserInterfaceStyle = state["dark"] as? Bool == true ? .dark : .light
    bar.semanticContentAttribute = state["rtl"] as? Bool == true ? .forceRightToLeft : .forceLeftToRight
  }
  func view() -> UIView { bar }
  func tabBar(_ tabBar: UITabBar, didSelect item: UITabBarItem) {
    UISelectionFeedbackGenerator().selectionChanged()
    channel.invokeMethod("select", arguments: item.tag)
  }
  deinit { channel.setMethodCallHandler(nil) }
}
