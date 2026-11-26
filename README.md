# DaVoice native iOS

[License](LICENSE) · [Model and Voice Asset Notice](MODEL_NOTICES.md) · [Third-party notices](THIRD_PARTY_NOTICES.md)

Native Swift examples for the DaVoice on-device voice libraries (wake word, speaker verification, speech to text, text to speech and
the on-device agent), the iOS counterpart of [Android Native DaVoice](https://github.com/frymanofer/Android_Native_Davoice).

By [DaVoice.io](https://davoice.io)

| Folder | What |
|---|---|
| [example_car_agent](example_car_agent/README.md) | DaVoice: AI Car Voice Agent, the native twin of the React Native / Flutter / Android car agent |
| libs/ | The DaVoice iOS frameworks (KeyWordDetection, DavoiceTTS, DavoiceLLM). `./update_libs.sh` refreshes them |

ONNX Runtime comes from the [DaVoiceOnnxRuntime](https://github.com/frymanofer/DaVoiceOnnxRuntime) Swift package.

The DaVoice libraries need a license key; the examples ship a temporary demo key. Contact info@davoice.io for your own.

## Models

| File | What |
|---|---|
| `example_car_agent/CarAgent/Resources/hey_davoice_model_28_06042026.dm` | "Hey DaVoice" wake word |
| `example_car_agent/CarAgent/Resources/layer1.dm` | Shared wake-word front end (required by every wake-word model) |
| `example_car_agent/CarAgent/Resources/sv.dm` | Speaker verification |
| Downloaded on first use | The voice of each language (about 170 MB), the DaVoice Automotive Agent 0.6B model (382 MB) and the router embedding model |

The models, voices and frameworks are for evaluation and non-commercial proof-of-concept use; see
[MODEL_NOTICES.md](MODEL_NOTICES.md). Commercial use needs a DaVoice license.

## Learn more on davoice.io

- [On-device voice-to-voice AI agent SDK](https://davoice.io/voice-agent-sdk): wake word, speech to text, a local LLM with tool calling and text to speech, with no per-token API fees
- [Wake word benchmark](https://davoice.io/wake-word-benchmark): two independent customer studies, DaVoice vs. commercial engines and openWakeWord
- [On-device speech to text SDK](https://davoice.io/speech-to-text): real-time and offline, no per-minute fees
- [On-device text to speech SDK and TTS API](https://davoice.io/text-to-speech): natural voices and voice cloning, no per-character fees
- [Run an LLM on the phone for a voice agent](https://davoice.io/voice-agent-guide/on-device-llm)
- [On-device tool calling for voice agents](https://davoice.io/voice-agent-guide/tool-calling)
- [Pricing](https://davoice.io/pricing): free license for proof-of-concept, academic and non-commercial projects

## Related

- [React Native DaVoice](https://github.com/frymanofer/ReactNative_DaVoice): the same car agent in React Native.
- [Android Native DaVoice](https://github.com/frymanofer/Android_Native_Davoice): the native Android (Kotlin) examples.

## License

The example source code is MIT (see [LICENSE](LICENSE)). The DaVoice frameworks in `libs/`, the models, the voices and the DaVoice
logo and images are not covered by the MIT license: see [MODEL_NOTICES.md](MODEL_NOTICES.md). Third-party code inside the frameworks
and the font are listed in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
