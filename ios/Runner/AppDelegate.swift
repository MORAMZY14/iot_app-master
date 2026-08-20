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
