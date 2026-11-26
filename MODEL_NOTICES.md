# Model, Voice and Framework Notice

The example source code is MIT-licensed (see [LICENSE](LICENSE)). That license does **not** apply to the
items below.

## What this notice covers

| Item | Where |
|---|---|
| "Hey DaVoice" wake word model | `example_car_agent/CarAgent/Resources/hey_davoice_model_28_06042026.dm` |
| Wake word front end | `example_car_agent/CarAgent/Resources/layer1.dm` |
| Speaker verification model | `example_car_agent/CarAgent/Resources/sv.dm` |
| Voices: the text-to-speech model and voice embeddings of each language | downloaded by the app (language packs, about 170 MB each) |
| DaVoice Automotive Agent 0.6B (the car agent model) and its pre-warmed states | downloaded by the app (382 MB) |
| Router embedding model | downloaded by the app |
| DaVoice frameworks: KeyWordDetection, DavoiceTTS, DavoiceLLM | `libs/` |

## Terms

The models, voices, voice embeddings and DaVoice frameworks are provided for evaluation, local testing,
experimentation, and non-commercial proof-of-concept applications based on this example.

You may build and test internal or non-commercial POCs with them, subject to the permissions applicable to
each model.

Commercial deployment, resale, redistribution, or inclusion of these models, voices or frameworks in a
commercial product requires a DaVoice license key and separate written permission or a commercial license.
Contact info@davoice.io.

Do not publish, extract, reverse engineer, decompile, disassemble, modify, repackage, or redistribute the
model files, voice assets or frameworks. Do not use them for training or to create derivative models unless
expressly permitted.

The license key in `example_car_agent/CarAgent/App/VoiceConfig.swift` is a temporary demo key for this
example only. Do not use it in your own apps.

## Open models these are based on

- **DaVoice Automotive Agent 0.6B** is a fine-tuned and quantized derivative of
  [Qwen3-0.6B](https://huggingface.co/Qwen/Qwen3-0.6B) by the Qwen team (Alibaba Cloud), licensed under the
  [Apache License 2.0](https://www.apache.org/licenses/LICENSE-2.0). DaVoice changed it: it was fine-tuned for
  in-car commands and quantized to q4_0.
- **The router embedding model** is [all-MiniLM-L6-v2](https://huggingface.co/sentence-transformers/all-MiniLM-L6-v2)
  by the Sentence Transformers project, licensed under the
  [Apache License 2.0](https://www.apache.org/licenses/LICENSE-2.0), converted to GGUF (Q8_0).

The Apache 2.0 terms apply to those base models. The DaVoice changes and the DaVoice-trained weights are
covered by the terms above.
