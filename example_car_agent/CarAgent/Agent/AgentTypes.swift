import Foundation

/// What an app tool returns: a plain result, or a result with the app's own sentence, said as it is (the turn ends without a second
/// model round).
enum ToolOutput {
    case value(JSON)
    case reply(result: JSON, say: String)

    /// The core's request answer: {"result": ...} or {"result": ..., "say": ...}.
    var coreAnswer: JSON {
        switch self {
        case .value(let v): return ["result": v]
        case .reply(let r, let say): return ["result": r, "say": JSON(say)]
        }
    }
}

/// One app tool the agent can call. handler runs on the agent's event queue and returns the result.
struct ToolDefinition {
    let name: String
    let description: String
    let inputSchema: JObj
    var execution: JObj?
    let handler: (_ args: JObj, _ context: JObj) throws -> ToolOutput
}

/// An agent event (see davoice_agent.h in the core): text, filler, status, webSearch, toolResult, skill, memory, log.
struct AgentEvent {
    let json: JObj
    var type: String { str(json["type"]) }
    var text: String { str(json["text"]) }
    var reason: String { str(json["reason"]) }
}

/// The result of one turn.
struct TurnResult {
    let json: JObj
    var text: String { str(json["text"]) }
    /// Keep these in the history with the reply.
    var toolMessages: [JObj] { asList(json["toolMessages"]).map { asObj($0) } }
    var cancelled: Bool { json["cancelled"] == true }
}
