# DaVoice native iOS

Native Swift examples for the DaVoice on-device voice libraries (wake word, speaker verification, speech to text, text to speech and
the on-device agent), the iOS counterpart of Android_Native_Davoice.

| Folder | What |
|---|---|
| [example_car_agent](example_car_agent/README.md) | DaVoice: AI Car Voice Agent, the native twin of the React Native / Flutter / Android car agent |
| libs/ | The DaVoice iOS frameworks (KeyWordDetection, DavoiceTTS, DavoiceLLM). `./update_libs.sh` refreshes them |


ONNX Runtime comes from the [DaVoiceOnnxRuntime](https://github.com/frymanofer/DaVoiceOnnxRuntime) Swift package.

The DaVoice libraries need a license key; the examples ship a temporary demo key. Contact info@davoice.io for your own.
