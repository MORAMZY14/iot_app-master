#include "OfflineVoiceAssistant.h"

OfflineVoiceAssistant::OfflineVoiceAssistant(
    const String& assistantName,
    DeviceIntentHandler deviceIntentHandler,
    LocalSpeechHandler localSpeechHandler)
    : assistantName_(assistantName),
      deviceIntentHandler_(deviceIntentHandler),
      localSpeechHandler_(localSpeechHandler) {}

void OfflineVoiceAssistant::setAssistantName(const String& assistantName) {
  assistantName_ = assistantName;
}

void OfflineVoiceAssistant::setRequireWakeWord(bool required) {
  requireWakeWord_ = required;
}

void OfflineVoiceAssistant::setDeviceIntentHandler(DeviceIntentHandler handler) {
  deviceIntentHandler_ = handler;
}

void OfflineVoiceAssistant::setLocalSpeechHandler(LocalSpeechHandler handler) {
  localSpeechHandler_ = handler;
}

OfflineAssistantResult OfflineVoiceAssistant::handle(
    const String& text,
    const String& language,
    bool requestSpeech) const {
  OfflineAssistantResult result;
  const String normalized = normalize(text);
  const bool arabic = language.startsWith("ar");

  if (normalized.length() == 0) {
    result.offlineReply = arabic ? "الأمر فارغ." : "The command is empty.";
    return result;
  }

  if (requireWakeWord_ && !hasWakeWord(normalized)) {
    result.offlineReply = arabic
        ? "قولي اسم المساعد أولاً."
        : "Say the assistant name first.";
    return result;
  }

  if (deviceIntentHandler_ != nullptr) {
    String deviceReply;
    if (deviceIntentHandler_(normalized, arabic, deviceReply)) {
      result.handled = true;
      result.needsFallback = false;
      result.reply = deviceReply.length() == 0
          ? (arabic ? "تم تنفيذ الأمر محلياً." : "The local command is complete.")
          : deviceReply;
      result.speakerQueued = queueSpeech(result.reply, arabic, requestSpeech);
      return result;
    }
  }

  static const char* const greetings[] = {
      "hello", "hi ", "hey", "good morning", "good evening",
      "مرحبا", "اهلا", "السلام عليكم"};
  static const char* const identity[] = {
      "your name", "who are you", "اسمك", "مين انت", "من انت"};
  static const char* const help[] = {
      "help", "what can you do", "commands", "مساعدة", "تقدر تعمل ايه",
      "الاوامر", "الأوامر"};
  static const char* const thanks[] = {
      "thank", "thanks", "شكرا", "متشكر"};

  if (containsAny(normalized, greetings, sizeof(greetings) / sizeof(greetings[0]))) {
    result.reply = arabic
        ? "أهلاً. المساعد يعمل محلياً على وحدة التحكم."
        : "Hello. The assistant is running locally on the controller.";
  } else if (containsAny(normalized, identity, sizeof(identity) / sizeof(identity[0]))) {
    result.reply = arabic
        ? String("اسمي ") + assistantName_ + ". وأعمل بدون سحابة."
        : String("My name is ") + assistantName_ + ". I work without the cloud.";
  } else if (containsAny(normalized, help, sizeof(help) / sizeof(help[0]))) {
    result.reply = arabic
        ? "يمكنني تنفيذ أوامر الغرف والأجهزة والحساسات المحلية."
        : "I can run local room, device, and sensor commands.";
  } else if (containsAny(normalized, thanks, sizeof(thanks) / sizeof(thanks[0]))) {
    result.reply = arabic ? "العفو." : "You are welcome.";
  } else {
    result.offlineReply = arabic
        ? "لم أفهم الأمر المحلي. جرّبي أمر جهاز أو غرفة."
        : "I did not understand that local command. Try a room or device command.";
    return result;
  }

  result.handled = true;
  result.needsFallback = false;
  result.speakerQueued = queueSpeech(result.reply, arabic, requestSpeech);
  return result;
}

String OfflineVoiceAssistant::normalize(const String& value) {
  String output = value;
  output.trim();
  output.toLowerCase();

  const char punctuation[] = {',', '.', '!', '?', ';', ':', '_', '-'};
  for (const char symbol : punctuation) {
    output.replace(symbol, ' ');
  }
  output.replace("،", " ");
  output.replace("؟", " ");
  output.replace("؛", " ");
  while (output.indexOf("  ") >= 0) {
    output.replace("  ", " ");
  }
  output.trim();
  return output;
}

bool OfflineVoiceAssistant::containsAny(
    const String& value,
    const char* const phrases[],
    size_t count) {
  for (size_t index = 0; index < count; ++index) {
    if (value.indexOf(phrases[index]) >= 0) return true;
  }
  return false;
}

bool OfflineVoiceAssistant::hasWakeWord(const String& normalizedText) const {
  String name = normalize(assistantName_);
  if (name.length() > 0 && normalizedText.indexOf(name) >= 0) return true;
  return normalizedText.indexOf("ellie") >= 0 ||
      normalizedText.indexOf("ايلي") >= 0 ||
      normalizedText.indexOf("إيلي") >= 0;
}

bool OfflineVoiceAssistant::queueSpeech(
    const String& reply,
    bool arabic,
    bool requested) const {
  if (!requested || localSpeechHandler_ == nullptr || reply.length() == 0) {
    return false;
  }
  return localSpeechHandler_(reply, arabic);
}
