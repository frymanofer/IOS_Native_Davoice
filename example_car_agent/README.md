# DaVoice: AI Car Voice Agent (native iOS)

An on-device voice assistant for a car, in native Swift and SwiftUI: **wake word → (optional) speaker verification → speech to text → the
DaVoice Automotive Agent (a fine-tuned 0.6B model running on the phone) → actions on a simulated car → text to speech.**

This is the native iOS twin of the React Native `example_car_agent`
([React Native DaVoice](https://github.com/frymanofer/ReactNative_DaVoice/tree/main/example_car_agent)) and of the native Android one
(Android_Native_Davoice). It has the same agent and car tools, the same replies and follow-ups, and the same conversation settings. The
car logic is checked against the same shared test cases as the other apps.

> The car is **simulated**. Nothing here talks to a real vehicle.

## What it does

1. **Language.** Choose one of 11 languages. Its voice (about 170 MB) downloads the first time; each file is sha256-checked.
2. **Voice.** Pick one of the language's voices. Tap a voice to hear it.
3. **Speaker verification** (optional). Record a voice signature by reading 5 sentences, use a saved one, or skip this step. With a
   signature, only your voice can open or unlock the doors, and the wake word answers only you.
4. **Say "Hey DaVoice".** The model (382 MB) downloads and warms up in the background meanwhile.
5. **Talk to the car.** For example: "Open the driver window", "I'm cold", "Take me home", "Lock the car", "Play Anitta",
   "Is the car locked?", "Undo that". The screen shows the car from above, what it heard, what ran, and the reply.

English and Brazilian Portuguese are tuned. In the other languages, the agent asks before every car action ("Soll ich das
Fahrerfenster öffnen?") and runs it only after a plain yes.

### Settings (the gear)

- **Conversation mode:** take turns or interrupt (echo cancellation), wake word before each request or just talk, and each mode's
  timeouts (end of speech, listening window, follow-up window, pre-fetch, the wake word as a stop word).
- **Local confidence:** a threshold on the model's score for its action, and what happens below it: *Clarify*, *Remote* or *Decline*.

## Build and run

Requirements: Xcode 16 or newer, an iPhone with iOS 15.1 or newer (arm64). The simulator runs everything but has no real microphone
routing; use a phone for the voice.

```bash
open CarAgent.xcodeproj          # select your team under Signing & Capabilities, then Run
```

- **ONNX Runtime.** For now the project uses a checkout of [DaVoiceOnnxRuntime](https://github.com/frymanofer/DaVoiceOnnxRuntime)
  next to this repository (`../../DaVoiceOnnxRuntime`). Once its Swift package is published, `DV_ORT=remote python3 tools/make_project.py`
  switches the project to the GitHub package.
- **Storage.** About 1.2 GB free: one voice (170 MB), the model (382 MB) and its pre-warmed start-up state (430 MB).
- **Debug builds** show suggestion chips and a text box under the microphone line, so you can try the agent without speaking.
- The app ships a temporary DaVoice demo license (`App/VoiceConfig.swift`). For your own key, contact info@davoice.io.

Command line (simulator), including the unit tests:

```bash
xcodebuild test -project CarAgent.xcodeproj -scheme CarAgent -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

Debug builds also have an autopilot that drives the whole flow and prints each step:

```bash
xcrun simctl launch --console-pty booted io.davoice.caragent.ios -autopilot "Open the driver window" "Lock the car"
```

## How it is put together

| Part | From |
|---|---|
| Wake word, speaker verification | `KeyWordDetection.xcframework` (`../libs`), driven through `Bridges/DVWakeWordCore` and `Bridges/DVSpeakerVerificationCore` |
| Speech to text + text to speech | `DavoiceTTS.xcframework`, driven through `Bridges/SpeechBridge` (the React Native package's own bridge, unchanged) |
| The agent and the model | `DavoiceLLM.xcframework` (`DavoiceAgent`, `LocalLLMEngine`), used directly from Swift |
| ONNX Runtime 1.31 | the `DaVoiceOnnxRuntime` Swift package (the same build as the `DaVoiceOnnxRuntime` pod) |

The Objective-C files in `Bridges/` are copies of the bridges the React Native and Cordova packages use, so the audio session, the
wake word, speech and their coordination behave exactly as in those apps. `Bridges/DVRNShim.h` stands in for the few React Native
types they use.

```
CarAgent/
  App/            the app flow (CarAgentApp), VoiceConfig (license, wake word, routing JSON), the debug autopilot
  Car/            the simulated car: state, tools (what each action does and says), undo, follow-ups, questions about the car,
                  the speech composer, media titles, the Basic-language flow
  Agent/          the DavoiceAgent client, the automotive pack, the model (download, warm-up, KV state), Local confidence
  Conversation/   the conversation modes: settings, the controller (who owns the microphone), the interrupt rule, the wake phrase
  Voice/          wake word, speech and speaker verification controllers (the same API as the React Native packages)
  TTS/            the language packs (voice downloads)
  Speaker/        the enrollment sentences and the owner check for the doors
  UI/             the SwiftUI screens and the car drawing
  Bridges/        the shared Objective-C bridges + the bridging header
  Resources/      the agent pack, the car's tool definitions and Basic-language sentences, the language-pack list, the wake-word
                  and speaker-verification models, fonts, images
CarAgentTests/    XCTest on the fixtures shared with the React Native, Flutter and Android apps
tools/make_project.py   writes CarAgent.xcodeproj from the folders (run it after adding or removing files)
```

The tool definitions (`Resources/car/carToolDefinitions.h3d.json`) are the wording the model was trained with. Keep them identical to
the other apps.

## What is not in this version

- Voice cloning (the React Native app's "clone a voice" screen).
- Remote updates to the language-pack list (the React Native app verifies a signed manifest).
- A remote assistant for general questions. As in the other apps' default, the agent says it isn't set up in this demo.
