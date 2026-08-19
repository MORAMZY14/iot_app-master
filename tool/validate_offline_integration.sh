#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
firmware="$project_root/esp32_firmware/SmartHomeOffline/SmartHomeOffline.ino"
voice="$project_root/lib/ellie/ellie_voice_controller.dart"
ble="$project_root/lib/ble_service.dart"
dashboard="$project_root/lib/dashboard_page.dart"

require_pattern() {
  local pattern="$1"
  local file="$2"
  if ! rg -q -- "$pattern" "$file"; then
    echo "Missing required integration pattern '$pattern' in $file" >&2
    exit 1
  fi
}

require_pattern 'POST /api/ellie|server\.on\("/api/ellie", HTTP_POST' "$firmware"
require_pattern 'server\.on\("/api/ellie/speak", HTTP_POST' "$firmware"
require_pattern 'server\.on\("/api/assistant/name", HTTP_POST' "$firmware"
require_pattern 'cmd == "ellie" \|\| cmd == "assistant"' "$firmware"
require_pattern 'cmd == "set_assistant_name"' "$firmware"
require_pattern 'SMART_HOME_FIRMWARE_VERSION "2\.6\.0-music-multidevice"' "$firmware"
require_pattern "resolve\('/api/ellie'\)" "$voice"
require_pattern "resolve\('/api/assistant/name'\)" "$voice"
require_pattern "'cmd': 'ellie'" "$ble"
require_pattern "'cmd': 'set_assistant_name'" "$ble"
require_pattern '_resolveAssistantEsp32Ip' "$dashboard"
require_pattern 'version: 2\.6\.0\+41' "$project_root/pubspec.yaml"
require_pattern '_ensureBleConnected' "$voice"
require_pattern '_configurePhoneAudioSession' "$voice"
require_pattern 'englishPowerPhrase' "$voice"
require_pattern 'crossAxisAlignment: CrossAxisAlignment\.stretch' "$dashboard"
require_pattern 'processPendingBleCommands' "$firmware"
require_pattern 'Non-blocking Firebase state uploader ready' "$firmware"
require_pattern 'responseSequence' "$firmware"
require_pattern 'I2C_TRANSACTION_TIMEOUT_MS' "$firmware"
require_pattern '_lastResponseSequence' "$ble"
require_pattern 'await refreshDevices\(\)' "$ble"
require_pattern 'LocalMusicIntentParser\.parse' "$voice"
require_pattern 'outputMode: EllieOutputMode\.phone' "$project_root/lib/ellie/ellie_assistant_sheet.dart"
require_pattern 'multiple_named_devices_on_off' "$firmware"
require_pattern 'shadowedByLongerName' "$firmware"
require_pattern 'just_audio: \^0\.9\.46' "$project_root/pubspec.yaml"
require_pattern 'audio_session: \^0\.1\.25' "$project_root/pubspec.yaml"
require_pattern 'FileType\.audio' "$project_root/lib/ellie/local_music_service.dart"
require_pattern 'getApplicationSupportDirectory' "$project_root/lib/ellie/local_music_storage_io.dart"
require_pattern 'smarthome/local_speech' "$voice"
require_pattern 'AVSpeechSynthesizer' "$project_root/ios/Runner/AppDelegate.swift"
if rg -q -- 'onEllie' "$dashboard"; then
  echo "The duplicate assistant action is still present in the top app bar" >&2
  exit 1
fi

if rg -q -- 'httpPatchSucceeded' "$firmware"; then
  echo "A synchronous command-triggered Firebase state PATCH remains" >&2
  exit 1
fi

firmware_service_uuid="$(sed -n 's/^#define BLE_SERVICE_UUID "\([^"]*\)"/\1/p' "$firmware")"
flutter_service_uuid="$(sed -n "s/^const String serviceUuid = '\([^']*\)';/\1/p" "$ble" | tr -d '\r')"
firmware_command_uuid="$(sed -n 's/^#define BLE_COMMAND_CHAR_UUID "\([^"]*\)"/\1/p' "$firmware")"
flutter_command_uuid="$(sed -n "s/^const String commandCharUuid = '\([^']*\)';/\1/p" "$ble" | tr -d '\r')"

if [[ -z "$firmware_service_uuid" || "$firmware_service_uuid" != "$flutter_service_uuid" ]]; then
  echo "BLE service UUID mismatch" >&2
  exit 1
fi
if [[ -z "$firmware_command_uuid" || "$firmware_command_uuid" != "$flutter_command_uuid" ]]; then
  echo "BLE command UUID mismatch" >&2
  exit 1
fi

if rg -q -- '/api/ellie/audio|needsCloud|ELLIE_BACKEND_URL|queueEllieAudioUrl' \
  "$firmware" "$voice" "$ble"; then
  echo "A removed cloud-assistant contract is still present" >&2
  exit 1
fi

echo "Offline assistant integration contract: OK"
echo "BLE service UUID: $firmware_service_uuid"
echo "BLE command UUID: $firmware_command_uuid"
