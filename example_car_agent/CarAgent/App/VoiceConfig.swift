import Foundation

/// What you would tune for your own app: license, wake word, speaker verification and the audio routing (the same values as the React
/// Native, Flutter and Android example_car_agent).
enum VoiceConfig {
    /// Temporary DaVoice demo license, valid for every DaVoice library (wake word, speaker verification, STT/TTS, local LLM). Contact
    /// info@davoice.io for your own key.
    static let davoiceLicenseKey = "DV2.eyJ2IjoyLCJraWQiOiJrMSIsImlkIjoiNzkzM2Y0MjcwMTMzIiwiY3VzdCI6IkRhVm9pY2UgZGVtbyBhcHAgSU9TX05hdGl2ZV9EYXZvaWNlL2V4YW1wbGVfY2FyX2FnZW50IChleGFjdCBhcHAgaWRzIG9ubHkpIiwiaWF0IjoxNzk1NzExMDc2MjMzLCJleHAiOjE4MzAyOTc2MDAwMDAsInByb2QiOlsiKiJdLCJwbGF0IjpbImlvcyJdLCJhcHBzIjp7ImlvcyI6WyJpby5kYXZvaWNlLmNhcmFnZW50LmlvcyJdfSwibW9kZWxzIjpbInR0cy8qIiwid3cvKiJdfQ.0n6A9-WCPm1hlls6XV49fHvnCHeGrJgLfqD7jwJQ-Go53i3QR_-eJejxSBieTlqkrIMsBkBKK6_CbhDce1wSlQ"

    struct WakeWordModel {
        let fileName: String
        let threshold: Float
        let bufferCount: Int
        let msBetweenCallbacks: Int
    }

    /// "Hey DaVoice", as the React Native car agent (Resources; the engine also needs its shared front end, layer1.dm, there).
    static let wakeWords = [WakeWordModel(fileName: "hey_davoice_model_28_06042026.dm", threshold: 0.999, bufferCount: 3, msBetweenCallbacks: 1000)]
    static let wakePhrase = "Hey DaVoice"

    // Speaker verification
    static let svModel = "sv.dm"
    static let svOnboardingSampleCount = 5
    /// iOS (the React Native app: 0.34 on Android, 0.35 on iOS).
    static let svDecisionThreshold = 0.35
    static let svEnrollmentFile = "sv_enrollment.json"
    /// The owner's id in the speaker set (doors only for this voice when speaker verification is on).
    static let svSpeakerId = "owner"

    /// The shared audio-routing JSON for wake word, STT and TTS (the speech library reads the wake word's routing JSON first). The
    /// conversation settings add AEC for the interrupt mode. Identical to the other apps, so all platforms share one config.
    static let audioRouting: JObj = [
        "WakewordAEC": ["regular": false, "duringTTS": false],
        "default": route(["mixWithOthers", "bluetoothHighQualityRecording", "allowAirPlay", "defaultToSpeaker"], "bluetoothHighQualityMic", "none"),
        "byOutputPort": [
            "carAudio": route(["mixWithOthers", "allowBluetooth", "allowBluetoothA2DP", "allowAirPlay", "overrideMutedMicrophoneInterruption"], "none"),
            "builtInReceiver": route(["mixWithOthers", "allowBluetoothA2DP", "allowAirPlay", "defaultToSpeaker"], "builtInMic"),
            "builtInSpeaker": route(["mixWithOthers", "allowBluetoothA2DP", "allowAirPlay", "defaultToSpeaker"], "builtInMic"),
            "bluetoothA2DP": route(["mixWithOthers", "bluetoothHighQualityRecording", "allowAirPlay"], "bluetoothHighQualityMic", "none"),
            "bluetoothHFP": route(["mixWithOthers", "bluetoothHighQualityRecording", "allowAirPlay"], "bluetoothHighQualityMic", "none"),
            "headphones": route(["mixWithOthers", "allowBluetoothA2DP", "allowAirPlay"], "builtInMic"),
        ],
        "WhenPlayingAudio": ["onPlay": ["options": ["duckOthers"]], "onFinishPlaying": ["notifyOthers": true]],
        "STTDuckingConfig": ["onUnpause": ["options": ["duckOthers"]], "onPause": ["notifyOthers": true]],
        "wakeWordDuringTTS": ["threshold": 0.9, "buffer_cnt": 1],
    ]

    private static func route(_ options: [String], _ preferredInput: String, _ forceFallback: String? = nil) -> JSON {
        var r: JObj = ["category": "playAndRecord", "mode": "default", "options": JSON(options), "preferredInput": JSON(preferredInput)]
        if let f = forceFallback { r["forceFallback"] = JSON(f) }
        return .obj(r)
    }

    static func audioRoutingJson(_ routing: JObj = audioRouting) -> String { Json.stringify(routing) }
}
