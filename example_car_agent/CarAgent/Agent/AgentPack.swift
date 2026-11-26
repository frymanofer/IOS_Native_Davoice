import Foundation

// The DaVoice Automotive Agent's pack (Resources/agent_automotive/[pt-BR/]agent.json, the same files as the other example_car_agent
// apps): the system prompt the automotive model is trained with, prompt templates, fixed replies and filler phrases. The native agent
// core interprets it. English and Brazilian Portuguese have their own pack; every other ("Basic") language uses the English pack with the
// sentences the user hears translated (basic_languages.json "pack").

enum AgentPack {
    private static var packs: [String: JObj] = [:]
    private static var basicPacks: [String: JObj] = [:]

    /// Loads the packs (read: a resource path -> its text).
    static func load(_ read: (String) throws -> String) throws {
        packs["en"] = try Json.obj(try read("agent_automotive/agent.json"))
        packs["pt-BR"] = try Json.obj(try read("agent_automotive/pt-BR/agent.json"))
        basicPacks = [:]
    }

    /// The pack of language (English for a language without its own pack).
    static func of(_ language: String) -> JObj { packs[language] ?? basicPack(language) ?? packs["en"]! }

    private static func basicPack(_ language: String) -> JObj? {
        guard let t = BasicLanguage.packTexts(language), !t.isEmpty, let en = packs["en"] else { return nil }
        if let cached = basicPacks[language] { return cached }
        var pack = en
        func s(_ k: String) -> String? { t[k]?.string }
        func list(_ k: String) -> JSON? { t[k]?.array.map { .arr($0.map { .str(str($0)) }) } }
        var prompts = asObj(pack["prompts"])
        for k in ["noReply", "notDoneRest", "done", "failed", "notConfirmed", "notAuthorized", "unsupported", "invalidArgs",
                  "guardConflict", "outOfRange", "outOfRangeAsk", "scopeClarify", "scopeUnsupported", "scopeNoRemote"] {
            if let v = s(k) { prompts[k] = JSON(v) }
        }
        pack["prompts"] = .obj(prompts)
        // "ok" is said in every language: the English "Okay!" (fixed reply "ack") is for the tuned languages only
        if let fixed = pack["fixedReplies"]?.array { pack["fixedReplies"] = .arr(fixed.filter { asObj($0)["id"] != "ack" }) }
        if var remote = pack["remote"]?.object {
            if let v = s("remoteFailed") { remote["failed"] = JSON(v) }
            var errors = asObj(remote["errors"])
            if let v = s("remoteOffline") { errors["offline"] = JSON(v) }
            if let v = s("remoteBusy") { errors["busy"] = JSON(v) }
            if let v = s("remoteTimeout") { errors["timeout"] = JSON(v) }
            if let v = s("remoteUnavailable") { errors["unavailable"] = JSON(v) }
            remote["errors"] = .obj(errors)
            if let v = list("remoteFillers") { remote["fillers"] = v }
            pack["remote"] = .obj(remote)
        }
        if let v = list("remoteFillers") { pack["onlineToolFillers"] = v }
        var web = asObj(pack["webSearch"])
        if var fillers = web["fillers"]?.object {
            if let v = list("searchFillers") { fillers["general"] = v }
            if let v = list("searchFailed") { fillers["searchFailed"] = v }
            fillers["topics"] = .arr([]) // topic fillers are English sentences
            web["fillers"] = .obj(fillers)
            pack["webSearch"] = .obj(web)
        }
        basicPacks[language] = pack
        return pack
    }

    /// agent with the language's reply instruction ending the persona, so it is part of the cached system prompt.
    static func withReplyLanguage(_ agent: JObj, _ language: String) -> JObj {
        var persona = asObj(agent["persona"])
        persona["systemPrompt"] = JSON("\(str(persona["systemPrompt"])) \(llmReplyInstructionFor(language))".trimmed)
        return agent + ["persona": .obj(persona)]
    }
}
