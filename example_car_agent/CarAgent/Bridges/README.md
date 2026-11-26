# Bridges

The Objective-C layer between the DaVoice frameworks and the Swift app. These files are copies of the bridges the other DaVoice
packages ship, so the wake word, speech, the audio session and their coordination behave exactly as in those apps:

| File | Copied from | Used by |
|---|---|---|
| SpeechBridge, DaVoiceTTSBridge, STTBridge (.h/.m) | react-native-davoice `ios/` (via cordova-speech `src/ios/`: only the React imports changed to DVRNShim.h) | Voice/SpeechController.swift |
| DVRNShim (.h/.m) | cordova-speech `src/ios/` | the three speech bridges (stands in for RCTEventEmitter, RCTConvert, the promise blocks) |
| DVWakeWordCore, DVSpeakerVerificationCore (.h/.m) | cordova-wake-word `src/ios/` (framework-neutral cores) | Voice/WakewordController.swift, Voice/SpeakerVerificationController.swift |
| SpeechBridge+Swift.h | this app | declares SpeechBridge's RCT_EXPORT_METHOD methods for Swift |
| CarAgent-Bridging-Header.h | this app | what Swift sees |

When the frameworks in `../../../libs` are updated, copy these files from the same package versions (they change together).
