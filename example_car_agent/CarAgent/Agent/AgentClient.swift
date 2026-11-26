import DavoiceLLM
import Foundation
import os

// The on-device voice assistant from the shared native agent core (DavoiceLLM.DavoiceAgent, the same core the React Native, Flutter and
// Android apps drive): one turn from the user's words to the spoken reply, with tool calling, fillers and the command scope. Its behaviour
// comes from an agent pack (Resources/agent_automotive/agent.json). The app supplies the pack, its own tools (the car's) and the UI. A
// Swift port of the other apps' agent client: JSON in and out, events streamed while a call runs.

final class AgentClient {
    private var native: DavoiceAgent!
    // Events and call results are handled on one queue, in the order the core sends them: every event of a call arrives before the
    // call's result.
    private let events = DispatchQueue(label: "DavoiceAgentEvents")
    private var listeners: [Int: (AgentEvent) -> Void] = [:]
    private var nextListener = 0
    private let lock = NSLock()
    private var tools: [String: ToolDefinition] = [:]
    private var closed = false
    private let onRequest: ((JObj) throws -> JSON)?
    private let log = Logger(subsystem: "io.davoice.caragent", category: "DavoiceAgent")

    // Latest-only prefill: partial transcripts arrive faster than they can be processed, and only the newest matters.
    private var prefillRunning = false
    private var prefillNext: JObj?

    struct Failure: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private init(onRequest: ((JObj) throws -> JSON)?) { self.onRequest = onRequest }

    /// Creates the agent on engine (its model is the agent's model). Throws when the pack is incomplete.
    static func create(engine: LocalLLMEngine, layer2: LocalLLMEngine, config: JObj, onEvent: ((AgentEvent) -> Void)?,
                       onRequest: ((JObj) throws -> JSON)?) throws -> AgentClient {
        let client = AgentClient(onRequest: onRequest)
        if let onEvent { _ = client.addListener(onEvent) }
        client.native = try DavoiceAgent(configJson: Json.stringify(config)) { [weak client] json in
            client?.events.async { client?.dispatch(json) }
        }
        client.native.attach(engine: engine)
        client.native.attachLayer2(engine: layer2)
        return client
    }

    private func dispatch(_ text: String) {
        guard let event = try? Json.obj(text) else { return }
        if event["type"] == "request" {
            answer(Int64(event["id"]?.double ?? 0), asObj(event["request"]))
            return
        }
        let e = AgentEvent(json: event)
        lock.lock()
        let ls = Array(listeners.values)
        lock.unlock()
        for l in ls { l(e) }
    }

    private func answer(_ id: Int64, _ request: JObj) {
        var result: JSON
        do {
            if request["type"] == "callTool" {
                guard let tool = withLock({ tools[str(request["name"])] }) else {
                    throw Failure(message: "There is no tool named \"\(str(request["name"]))\".")
                }
                // the car's state is the screen's too: tools run on the main thread
                let args = asObj(request["arguments"])
                let context = asObj(request["context"])
                var output: Result<ToolOutput, Error>!
                DispatchQueue.main.sync { output = Result { try tool.handler(args, context) } }
                result = try output.get().coreAnswer
            } else if let onRequest {
                result = try onRequest(request)
            } else {
                throw Failure(message: "The app does not answer \"\(str(request["type"]))\" requests.")
            }
        } catch {
            result = ["error": JSON(error.localizedDescription)]
        }
        native.resolve(id: id, resultJson: Json.stringify(result))
    }

    private func withLock<T>(_ f: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return f()
    }

    /// Runs a core method (see davoice_agent.h); returns its decoded result.
    func call(_ method: String, _ args: JObj = JObj()) async throws -> JSON? {
        if withLock({ closed }) { throw Failure(message: "The agent was closed") }
        return try await withCheckedThrowingContinuation { c in
            native.callAsync(method: method, argsJson: Json.stringify(args)) { [events] result, error in
                // after every event of this call (same queue)
                events.async {
                    if let error { c.resume(throwing: error) } else { c.resume(returning: result.flatMap { parseJSON($0) }) }
                }
            }
        }
    }

    /// One turn: tools, reply. Text streams as `text` events; fillers come as `filler` events. Load a model first. input: text,
    /// history, date, ...
    func turn(_ input: JObj, onEvent: ((AgentEvent) -> Void)? = nil) async throws -> TurnResult {
        let remove = onEvent.map { addListener($0) }
        defer { remove?() }
        return TurnResult(json: asObj(try await call("turn", input)))
    }

    /// Processes the conversation plus the user's words so far into the model's cache. Never throws.
    func prefill(_ history: [JObj], _ partialText: String = "") {
        lock.lock()
        prefillNext = ["history": JSON(history), "text": JSON(partialText)]
        if prefillRunning {
            lock.unlock()
            return
        }
        prefillRunning = true
        lock.unlock()
        prefillStep()
    }

    private func prefillStep() {
        lock.lock()
        let next = prefillNext
        prefillNext = nil
        if next == nil || closed { prefillRunning = false }
        lock.unlock()
        guard let next, !closed else { return }
        native.callAsync(method: "prefill", argsJson: Json.stringify(next)) { [weak self] _, _ in
            self?.events.async { self?.prefillStep() }
        }
    }

    /// Stops the running turn.
    func cancel() async { _ = try? await call("cancel") }

    /// Changes settings at runtime.
    func configure(_ settings: JObj) async throws { _ = try await call("configure", settings) }

    /// The app's own tools. online tools get a filler while they run.
    func setTools(_ list: [ToolDefinition], online: (ToolDefinition) -> Bool = { _ in false }) async throws {
        withLock { tools = Dictionary(uniqueKeysWithValues: list.map { ($0.name, $0) }) }
        let defs: [JSON] = list.map { t in
            var m: JObj = ["name": JSON(t.name), "description": JSON(t.description), "inputSchema": .obj(t.inputSchema)]
            if let e = t.execution { m["execution"] = .obj(e) }
            m["online"] = JSON(online(t))
            return .obj(m)
        }
        try await configure(["externalTools": .arr(defs)])
    }

    func addListener(_ l: @escaping (AgentEvent) -> Void) -> () -> Void {
        lock.lock()
        let id = nextListener
        nextListener += 1
        listeners[id] = l
        lock.unlock()
        return { [weak self] in self?.withLock { _ = self?.listeners.removeValue(forKey: id) } }
    }

    func close() {
        lock.lock()
        if closed {
            lock.unlock()
            return
        }
        closed = true
        listeners.removeAll()
        lock.unlock()
        native.close()
    }
}
