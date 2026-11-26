import Foundation
import os

// The one model of the car agent (as the other example_car_agent apps): DaVoice Automotive Agent 0.6B (g3c_it3639, Qwen3-0.6B fine-tuned
// for the car, q4_0, 382 MB), downloaded on first use, sha256-checked; and its pre-warmed KV states (the system prompt already processed,
// per language), so the first start does not spend ~40 s processing the prompt on the phone.

struct PrebuiltState {
    let url: String
    let sha256: String
    let sizeBytes: Int64
}

enum CarModel {
    static let id = "davoice-automotive-agent-0.6b-g3c-it3639"
    static let displayName = "DaVoice Automotive Agent 0.6B"
    static let fileName = "davoice-automotive-qwen3-0.6b-g3c-it3639-q4_0.gguf"
    private static let r2 = "https://pub-27f94b1602c647ab95a601086cf52820.r2.dev/agent-llm"
    static let url = "\(r2)/auto16_g3c_it3639-q4_0.gguf"
    static let sizeBytes: Int64 = 381_565_920
    static let sha256 = "c39fbd65b259573d67dfb7da1935f1d0087156d7eefd97e131536a436c4d0ba8"

    /// Same decisions as 8192 on the phone, 0.23 GB less.
    static let contextSize = 6144

    /// Qwen3's chat format, thinking off.
    static let chatTemplate: JObj = [
        "systemPrefix": "<|im_start|>system\n",
        "userPrefix": "<|im_start|>user\n",
        "assistantPrefix": "<|im_start|>assistant\n",
        "turnSuffix": "<|im_end|>\n",
        "systemMode": "role",
        "stopSequences": ["<|im_end|>"],
        "generationPrefix": "<think>\n\n</think>\n\n",
        "spacedToolJson": true,
    ]

    // The model's agent settings (the same as the other apps' model registry entry).
    static let toolWording = "h3d"
    static let callGuards = "correct"
    static let historyAsRun = true
    static let guidedToolCalls = true
    static let promptOrder = "cache"
    static let guardRetry = true
    static let maxOperations = 2
    static let historyTurns = 6
    static let compactToolResults = true
    static let scope: JObj = ["enabled": true, "localMaxWords": 10, "strictMaxWords": 15, "hardMaxWords": 22]
    static let undo = true

    static let prebuiltStates = [
        "en": PrebuiltState(url: "\(r2)/prewarm/g3c_it3639_prewarm_en.kvstate",
                            sha256: "75a35e15c774b9b63223b4b71e3283f6abffbf3b52e6343f16b04d9f26cd325f", sizeBytes: 426_699_589),
        "pt-BR": PrebuiltState(url: "\(r2)/prewarm/g3c_it3639_prewarm_pt-BR.kvstate",
                               sha256: "f794a202844afdcb754678ce092da729dbdc66377c5e39c78d81300c683f11a0", sizeBytes: 429_681_893),
    ]
}

final class ModelStore {
    let dir: URL
    private let log = Logger(subsystem: "io.davoice.caragent", category: "LocalLLM")

    /// The newest saved states kept (each is ~430 MB).
    static let kvStatesKept = 2

    init() {
        dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("local_llm/models")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // ~800 MB of model and state: not for iCloud backups
        var d = dir
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? d.setResourceValues(values)
    }

    var modelFile: URL { dir.appendingPathComponent(CarModel.fileName) }
    func isDownloaded() -> Bool { FileManager.default.fileExists(atPath: modelFile.path) }

    private var kvPrefix: String { "\(CarModel.fileName).\(CarModel.sha256.prefix(12)).ctx\(CarModel.contextSize)." }

    /// A saved KV state for the prompt's system part (promptKey, see stablePromptKey).
    func kvStatePath(_ promptKey: String) -> String { dir.appendingPathComponent("\(kvPrefix)\(promptKey).kvstate").path }
    private func prebuiltStatePath(_ language: String) -> URL { dir.appendingPathComponent("\(kvPrefix)prebuilt-\(language).kvstate") }

    /// Downloads the model (sha256 checked; a temporary file renamed when complete).
    func download(_ onProgress: @escaping (Double) -> Void) async throws {
        if isDownloaded() { return }
        try await Downloader.fetch(URL(string: CarModel.url)!, to: modelFile, sha256: CarModel.sha256, expectedBytes: CarModel.sizeBytes) {
            onProgress(Double($0) / Double(CarModel.sizeBytes))
        }
    }

    /// The pre-warmed state of language, downloaded if there is one and the phone has not saved its own; nil when none. A failure only
    /// logs: the phone then warms up itself.
    func downloadPrebuiltState(_ language: String, _ onProgress: @escaping (Double) -> Void) async -> String? {
        guard let entry = CarModel.prebuiltStates[language] else { return nil }
        let dest = prebuiltStatePath(language)
        if FileManager.default.fileExists(atPath: dest.path) { return dest.path }
        // the phone already saved its own state for this language (states are named "<language>-<prompt hash>")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        if names.contains(where: { $0.hasPrefix("\(kvPrefix)\(language)-") && $0.hasSuffix(".kvstate") }) { return nil }
        do {
            try await Downloader.fetch(URL(string: entry.url)!, to: dest, sha256: entry.sha256, expectedBytes: entry.sizeBytes) {
                onProgress(Double($0) / Double(entry.sizeBytes))
            }
            return dest.path
        } catch {
            log.warning("pre-warmed state not downloaded (the phone warms up itself): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Saved states: the newest kvStatesKept are kept, the others deleted.
    func deleteOldStates() {
        let fm = FileManager.default
        let urls = ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { $0.lastPathComponent.hasSuffix(".kvstate") || $0.lastPathComponent.hasSuffix(".kvstate.tmp") }
        func date(_ u: URL) -> Date { (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast }
        var kept = 0
        for u in urls.sorted(by: { date($0) > date($1) }) {
            let n = u.lastPathComponent
            if n.hasPrefix(kvPrefix) && !n.hasSuffix(".tmp") && kept < Self.kvStatesKept {
                kept += 1
                continue
            }
            try? fm.removeItem(at: u)
        }
    }
}

/// Which saved state fits this prompt: a hash of its system part WITHOUT the date line (which changes every day). FNV-1a, 32 bits over
/// UTF-16 code units, the same value as the other apps' stablePromptKey.
func stablePromptKey(_ prompt: String, _ dateText: String) -> String {
    let system = prompt.range(of: "<|im_start|>user").map { String(prompt[..<$0.lowerBound]) } ?? prompt
    let withoutDate = system.components(separatedBy: dateText).joined()
    var h: UInt32 = 0x811c_9dc5
    for unit in withoutDate.utf16 {
        h ^= UInt32(unit)
        h = h &* 0x0100_0193
    }
    let hex = String(h, radix: 16)
    return String(repeating: "0", count: max(0, 8 - hex.count)) + hex
}
