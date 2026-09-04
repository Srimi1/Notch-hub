import Foundation
import Testing
@testable import NotchHubMedia

@Suite("Bounded adapter line accumulation")
struct LineAccumulatorTests {
    @Test("Complete lines are emitted in order")
    func emitsCompleteLines() {
        let accumulator = LineAccumulator()

        #expect(
            accumulator.append(Data("one\ntwo\n".utf8))
                == LineAccumulatorResult(lines: ["one", "two"], discarded: false)
        )
    }

    @Test("A line split across reads is reassembled")
    func reassemblesSplitLine() {
        let accumulator = LineAccumulator()

        #expect(accumulator.append(Data("{\"type\":\"da".utf8)).lines.isEmpty)
        #expect(
            accumulator.append(Data("ta\"}\n".utf8))
                == LineAccumulatorResult(lines: [#"{"type":"data"}"#], discarded: false)
        )
    }

    @Test("Only an unterminated tail is returned by flush")
    func flushesTailOnce() {
        let accumulator = LineAccumulator()

        #expect(accumulator.append(Data("done\nhalf".utf8)).lines == ["done"])
        #expect(accumulator.flush() == "half")
        #expect(accumulator.flush() == nil)
    }

    @Test("Invalid UTF-8 is discarded while later lines still recover")
    func rejectsInvalidEncoding() {
        let accumulator = LineAccumulator()
        var bytes = Data([0xFF, 0xFE, UInt8(ascii: "\n")])
        bytes.append(Data("valid\n".utf8))

        #expect(
            accumulator.append(bytes)
                == LineAccumulatorResult(lines: ["valid"], discarded: true)
        )
    }

    @Test("An endless line cannot exceed the fixed memory bound")
    func dropsOversizedLineAndRecovers() {
        let accumulator = LineAccumulator()
        let oversized = Data(
            repeating: UInt8(ascii: "x"),
            count: LineAccumulator.maximumBufferedBytes + 1
        )

        #expect(accumulator.append(oversized) == LineAccumulatorResult(lines: [], discarded: true))
        #expect(
            accumulator.append(Data("discarded-tail\nafter\n".utf8))
                == LineAccumulatorResult(lines: ["after"], discarded: false)
        )
        #expect(accumulator.flush() == nil)
    }

    @Test("A large chunk of individually bounded lines is preserved")
    func preservesManyBoundedLinesInOneChunk() {
        let accumulator = LineAccumulator()
        let lineCount = 24_000
        let chunk = Data(String(repeating: "ok\n", count: lineCount).utf8)

        let result = accumulator.append(chunk)

        #expect(chunk.count > LineAccumulator.maximumBufferedBytes)
        #expect(result.lines.count == lineCount)
        #expect(result.lines.first == "ok")
        #expect(result.lines.last == "ok")
        #expect(!result.discarded)
    }
}
