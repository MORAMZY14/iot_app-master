#pragma once

#include <Arduino.h>

struct OfflineAssistantResult {
  bool handled = false;
  bool needsFallback = true;
  bool speakerQueued = false;
  String reply;
  String offlineReply;
};

class OfflineVoiceAssistant {
 public:
  using DeviceIntentHandler = bool (*)(
      const String& normalizedText,
      bool arabic,
      String& reply);
  using LocalSpeechHandler = bool (*)(const String& text, bool arabic);

  explicit OfflineVoiceAssistant(
      const String& assistantName = "Ellie",
      DeviceIntentHandler deviceIntentHandler = nullptr,
      LocalSpeechHandler localSpeechHandler = nullptr);

  void setAssistantName(const String& assistantName);
  void setRequireWakeWord(bool required);
  void setDeviceIntentHandler(DeviceIntentHandler handler);
  void setLocalSpeechHandler(LocalSpeechHandler handler);

  OfflineAssistantResult handle(
      const String& text,
      const String& language = "en",
      bool requestSpeech = true) const;

 private:
  String assistantName_;
  DeviceIntentHandler deviceIntentHandler_;
  LocalSpeechHandler localSpeechHandler_;
  bool requireWakeWord_ = false;

  static String normalize(const String& value);
  static bool containsAny(const String& value, const char* const phrases[], size_t count);
  bool hasWakeWord(const String& normalizedText) const;
  bool queueSpeech(const String& reply, bool arabic, bool requested) const;
};
