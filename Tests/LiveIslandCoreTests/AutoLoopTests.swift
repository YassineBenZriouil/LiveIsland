import Foundation
import Testing
@testable import LiveIslandCore

@Suite("auto loop")
struct AutoLoopTests {
    private let record = AutoLoopRecord(pid: 4242, startedAt: 1_795_000_000.123456)

    @Test func endsOnlyTheLoopLiveIslandLeft() {
        let left = AutoLoopRecord.Running(pid: 4242, parent: 1, startedAt: 1_795_000_000.123456,
                                          arguments: ["/usr/bin/python3", "/Users/me/.local/bin/cswap", "auto", "--json"])
        #expect(record.isOrphan(left))
        #expect(!record.isOrphan(nil), "already gone")
        var adopted = left
        adopted.parent = 812
        #expect(!record.isOrphan(adopted), "still has a parent: LiveIsland or a shell runs it")
        var reused = left
        reused.startedAt += 30
        #expect(!record.isOrphan(reused), "the pid went to another process")
        var other = left
        other.arguments = ["/usr/bin/python3", "/Users/me/.local/bin/cswap", "tui"]
        #expect(!record.isOrphan(other))
        var typed = left
        typed.arguments = ["/usr/bin/python3", "/Users/me/.local/bin/cswap", "auto"]
        #expect(!record.isOrphan(typed), "a loop typed in Terminal prints for people, not --json")
    }

    @Test func keepsItsRecordAsJSON() throws {
        let data = record.encoded()
        #expect(try #require(AutoLoopRecord.decode(data)) == record)
        #expect(AutoLoopRecord.decode(Data(#"{"pid":"x"}"#.utf8)) == nil)
        #expect(AutoLoopRecord.decode(Data(#"{"pid":7,"startedAt":1795000000.5}"#.utf8)) == AutoLoopRecord(pid: 7, startedAt: 1_795_000_000.5))
    }
}
