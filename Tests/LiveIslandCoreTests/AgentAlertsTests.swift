import Foundation
import Testing
@testable import LiveIslandCore

/// A tool call left waiting at the end of a transcript, as Claude Code writes it.
private func toolUse(_ name: String, input: String) -> String {
    Fixture.claudeAssistant(content: #"[{"type":"tool_use","id":"toolu_1","name":"\#(name)","input":\#(input),"caller":{"type":"direct"}}]"#)
}

private func request(_ lines: [String], state: AgentState) -> AgentRequest? {
    ClaudeTranscript.request(of: ClaudeTranscript.tail(of: lines.map(Fixture.data)), state: state)
}

private func session(_ id: String, _ state: AgentState, request: AgentRequest? = nil, project: String = "app") -> AgentSession {
    AgentSession(id: "/Users/me/.claude/projects/-Users-me-Code-app/\(id).jsonl", kind: .claude, project: project,
                 state: state, lastActivity: Date(timeIntervalSince1970: 1_792_000_000), request: request)
}

@Suite("Agent alerts: when to tell the person an agent needs them")
struct AgentAlertsTests {
    private let bash = request([Fixture.claudePrompt(), toolUse("Bash", input: #"{"command":"npm test","description":"Run the tests"}"#)],
                               state: .waiting)

    @Test func theFirstLookOnlyRemembers() {
        var alerts = AgentAlerts()
        let first = alerts.update([session("a", .waiting, request: bash)])
        #expect(first.started.isEmpty, "what was already waiting at launch isn't announced")
        #expect(first.ended.isEmpty)
    }

    @Test func startingToWaitIsAnnouncedOnce() {
        var alerts = AgentAlerts()
        _ = alerts.update([session("a", .working)])
        let next = alerts.update([session("a", .waiting, request: bash)])
        #expect(next.started.map(\.project) == ["app"])
        #expect(alerts.update([session("a", .waiting, request: bash)]).started.isEmpty, "still waiting: no second notification")
    }

    @Test func aNewSessionThatWaitsIsAnnounced() {
        var alerts = AgentAlerts()
        _ = alerts.update([])
        #expect(alerts.update([session("b", .waiting)]).started.count == 1)
    }

    @Test func answeringEndsIt() {
        var alerts = AgentAlerts()
        _ = alerts.update([session("a", .working)])
        _ = alerts.update([session("a", .waiting, request: bash)])
        let after = alerts.update([session("a", .working)])
        #expect(after.started.isEmpty)
        #expect(after.ended == [session("a", .working).id])
    }

    @Test func aTurnEndingOnAQuestionNeedsThePerson() throws {
        let question = try #require(request([Fixture.claudePrompt(),
                                             Fixture.claudeAssistant(stop: "end_turn", content: #"[{"type":"text","text":"Done.\n\nShould I push it to main?"}]"#)],
                                            state: .done))
        #expect(AgentAlerts.needsPerson(session("a", .done, request: question)))
        #expect(!AgentAlerts.needsPerson(session("a", .done)), "a plain finish is Done, not Needs you")
        #expect(!AgentAlerts.needsPerson(session("a", .idle, request: question)), "an old question in an idle session is history")
        #expect(!AgentAlerts.needsPerson(session("a", .working)))
    }

    @Test func theMessageSaysWhatItAsks() throws {
        let message = AgentAlerts.message(for: session("a", .waiting, request: bash), hidingDetails: false)
        #expect(message.title == "Claude Code needs you")
        #expect(message.body == "app: Bash: Run the tests")
        let bare = AgentAlerts.message(for: session("a", .waiting), hidingDetails: false)
        #expect(bare.body == "app: Needs permission")
    }

    @Test func whileSharingTheMessageKeepsDetailsOut() throws {
        let question = AgentRequest(kind: .question, summary: "Should I delete the customer table?")
        let message = AgentAlerts.message(for: session("a", .done, request: question, project: "secret-client"), hidingDetails: true)
        #expect(message.title == "Claude Code needs you")
        #expect(message.body == "Has a question")
        #expect(!message.body.contains("secret"))
        let permission = AgentAlerts.message(for: session("a", .waiting, request: bash, project: "secret-client"), hidingDetails: true)
        #expect(permission.body == "Needs permission")
    }
}

@Suite("Agent request: the closed island's short label")
struct AgentRequestLabelTests {
    @Test func aToolGoesByItsName() throws {
        let bash = try #require(request([toolUse("Bash", input: #"{"command":"ls"}"#)], state: .waiting))
        #expect(bash.compactLabel == "Bash?")
        #expect(bash.symbol == "hand.raised.fill")
    }

    @Test func anMCPToolDropsItsServer() throws {
        let search = try #require(request([toolUse("mcp__github__search", input: #"{"query":"open bugs"}"#)], state: .waiting))
        #expect(search.compactLabel == "search?")
    }

    @Test func longNamesFitTheWing() {
        let label = AgentRequest(kind: .permission, tool: "NotebookEdit").compactLabel
        #expect(label.count <= AgentRequest.compactLength)
        #expect(label == "Noteboo…?")
        #expect(AgentRequest(kind: .permission, tool: "mcp__x__").compactLabel == "mcp__x__?", "no name after the prefix: the whole tool")
    }

    @Test func questionsAndUnknownsSayWhatTheyAre() throws {
        let input = #"{"questions":[{"question":"Which database should I use?","header":"Database","options":[{"label":"SQLite"}],"multiSelect":false}]}"#
        let ask = try #require(request([toolUse("AskUserQuestion", input: input)], state: .waiting))
        #expect(ask.compactLabel == "Question")
        #expect(ask.symbol == "questionmark.bubble.fill")
        #expect(AgentRequest(kind: .permission).compactLabel == "Needs you")
    }
}
