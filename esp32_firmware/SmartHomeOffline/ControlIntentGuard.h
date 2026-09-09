#pragma once
#include <string>

namespace HomeIntent {
inline bool phrase(const std::string& text, const std::string& value) {
  return (" " + text + " ").find(" " + value + " ") != std::string::npos;
}
template <size_t N> bool any(const std::string& text, const char* const (&values)[N]) {
  for (const char* value : values) if (phrase(text, value)) return true;
  return false;
}
struct PowerRequest { int state; bool blocked; };
inline PowerRequest inspect(const std::string& text) {
  const char* const on[] = {"turn on", "switch on", "power on", "activate", "شغل", "شغلي", "افتح", "افتحي", "تشغيل"};
  const char* const off[] = {"turn off", "switch off", "power off", "deactivate", "shut down", "اطفي", "اطفئ", "اطفي", "اقفل", "اقفلي", "اغلق", "اطفاء"};
  const bool verb = phrase(text, "turn") || phrase(text, "switch") || phrase(text, "power");
  const bool wantsOn = any(text, on) || (verb && phrase(text, "on"));
  const bool wantsOff = any(text, off) || (verb && phrase(text, "off"));
  const char* const uncertain[] = {"not", "dont", "don't", "don t", "never", "except", "unless", "if", "when", "later", "after", "before", "tomorrow", "instead", "without", "but", "لا", "مش", "متشغلش", "ما تشغلش", "ما تطفيش", "متطفيش", "الا", "إلا", "غير", "لو", "لما", "بعد", "قبل", "بكره", "بكرة", "بدون"};
  const bool blocked = (wantsOn && wantsOff) || ((wantsOn || wantsOff) && any(text, uncertain));
  return {wantsOn ? 1 : wantsOff ? 0 : -1, blocked};
}
}
