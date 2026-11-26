import CryptoKit
import Foundation

// The voice of each language: a TTS model (every voice of the language is a speaker of it) and the voice-clone encoder, downloaded from
// baseUrl on first use (Resources/language_packs.json: the same files and checksums as the other car apps; none is bundled here). A file
// is checked against its sha256 before it is used.

struct PackFile {
    let file: String
    let bytes: Int64
    let sha256: String
}

final class LanguagePacks {
    private let root: URL
    private let baseUrl: String
    private let packs: [String: [String: PackFile]]

    init(_ json: String) throws {
        root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("language_packs")
        let config = try Json.obj(json)
        var b = str(config["baseUrl"])
        while b.hasSuffix("/") { b.removeLast() }
        baseUrl = b
        var p: [String: [String: PackFile]] = [:]
        for (lang, v) in asObj(config["languages"]) {
            var files: [String: PackFile] = [:]
            for (kind, f) in asObj(v) {
                let o = asObj(f)
                files[kind] = PackFile(file: str(o["file"]), bytes: Int64(o["bytes"]?.double ?? 0), sha256: str(o["sha256"]).lowercased())
            }
            p[lang] = files
        }
        packs = p
    }

    var languages: Set<String> { Set(packs.keys) }

    private func versionDir(_ language: String) -> URL {
        let p = packs[language]!
        return root.appendingPathComponent("\(language)/\(p["model"]!.sha256.prefix(12))-\(p["embedder"]!.sha256.prefix(12))")
    }

    private func path(_ language: String, _ kind: String) -> URL { versionDir(language).appendingPathComponent(packs[language]![kind]!.file) }

    private func size(_ url: URL) -> Int64 { ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? -1 }

    /// Both files of the language on the phone (complete).
    func isReady(_ language: String) -> Bool {
        guard let p = packs[language] else { return false }
        return ["model", "embedder"].allSatisfy { size(path(language, $0)) == p[$0]!.bytes }
    }

    /// The download size still missing for language, in bytes.
    func missingBytes(_ language: String) -> Int64 {
        guard let p = packs[language] else { return 0 }
        return ["model", "embedder"].filter { size(path(language, $0)) != p[$0]!.bytes }.reduce(Int64(0)) { $0 + p[$1]!.bytes }
    }

    /// The TTS model of language (the English one for a language without a pack).
    func modelPath(_ language: String) -> String { path(packs[language] != nil ? language : "en", "model").path }

    /// The voice-clone encoder of language.
    func embedderPath(_ language: String) -> String { path(packs[language] != nil ? language : "en", "embedder").path }

    struct Failure: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Downloads what is missing (onProgress: done, total bytes). Checks each file's sha256; a bad file is deleted.
    func download(_ language: String, onProgress: @escaping (Int64, Int64) -> Void) async throws {
        guard let p = packs[language] else { throw Failure(message: "No voice for \(language)") }
        let missing = ["model", "embedder"].filter { size(path(language, $0)) != p[$0]!.bytes }
        let total = missing.reduce(Int64(0)) { $0 + p[$1]!.bytes }
        var done: Int64 = 0
        for kind in missing {
            let f = p[kind]!
            let dest = path(language, kind)
            try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard let url = URL(string: "\(baseUrl)/\(f.file)") else { throw Failure(message: "Bad URL for \(f.file)") }
            let before = done
            try await Downloader.fetch(url, to: dest, sha256: f.sha256, expectedBytes: f.bytes) { got in
                onProgress(before + got, total)
            }
            done += f.bytes
        }
        onProgress(total, total)
    }
}

/// A download with progress and a sha256 check (a temporary file renamed when complete), shared by the language packs and the model.
enum Downloader {
    struct Failure: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private final class Delegate: NSObject, URLSessionDataDelegate {
        let handle: FileHandle
        var hasher = SHA256()
        var received: Int64 = 0
        var lastReport = Date.distantPast
        let onBytes: (Int64) -> Void
        var completion: ((Error?) -> Void)?
        var status = 200

        init(_ handle: FileHandle, _ onBytes: @escaping (Int64) -> Void) {
            self.handle = handle
            self.onBytes = onBytes
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            status = (response as? HTTPURLResponse)?.statusCode ?? 200
            completionHandler(status == 200 ? .allow : .cancel)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            handle.write(data)
            hasher.update(data: data)
            received += Int64(data.count)
            let now = Date()
            if now.timeIntervalSince(lastReport) > 0.1 {
                lastReport = now
                onBytes(received)
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            completion?(error ?? (status == 200 ? nil : Failure(message: "Download failed: HTTP \(status)")))
            completion = nil
        }
    }

    static func fetch(_ url: URL, to dest: URL, sha256: String, expectedBytes: Int64, onBytes: @escaping (Int64) -> Void) async throws {
        let temp = dest.appendingPathExtension("download")
        try? FileManager.default.removeItem(at: temp)
        FileManager.default.createFile(atPath: temp.path, contents: nil)
        let handle = try FileHandle(forWritingTo: temp)
        let delegate = Delegate(handle, onBytes)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        do {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                delegate.completion = { error in
                    if let error { c.resume(throwing: error) } else { c.resume() }
                }
                session.dataTask(with: url).resume()
            }
            try handle.close()
            let hex = delegate.hasher.finalize().map { String(format: "%02x", $0) }.joined()
            if hex != sha256.lowercased() { throw Failure(message: "The downloaded file is damaged (checksum). Please try again.") }
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: temp, to: dest)
            onBytes(expectedBytes)
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
    }
}
