#!/bin/bash
# Copies the DaVoice iOS frameworks into libs/ from the published React Native packages of a project next to this repository
# (default: ../ReactNative_DaVoice/example_car_agent/node_modules), then prints each framework's version and size, so a stale copy
# is obvious. The Objective-C bridges in example_car_agent/CarAgent/Bridges must match the frameworks: copy them from the same
# package versions (react-native-davoice ios/SpeechBridge, TTSRNBridge, STTRNBridge; the Cordova plugins' DV*Core files).
set -e
cd "$(dirname "$0")"
NM="${1:-../ReactNative_DaVoice/example_car_agent/node_modules}"
cp_fw() { rm -rf "libs/$(basename "$1")"; cp -a "$1" libs/; }
mkdir -p libs
cp_fw "$NM/react-native-wakeword/ios/KeyWordRNBridge/KeyWordDetection.xcframework"
cp_fw "$NM/react-native-davoice/ios/TTSRNBridge/DavoiceTTS.xcframework"
cp_fw "$NM/react-native-davoice-llm/ios/LocalLLMRNBridge/DavoiceLLM.xcframework"
for p in react-native-wakeword react-native-davoice react-native-davoice-llm; do
  printf '%-28s %s\n' "$p" "$(sed -n 's/.*"version": *"\(.*\)".*/\1/p' "$NM/$p/package.json" | head -1)"
done
du -sh libs/*.xcframework
