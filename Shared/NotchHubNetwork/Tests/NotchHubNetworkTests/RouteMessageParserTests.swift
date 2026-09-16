import Darwin
import Foundation
import Testing
@testable import NotchHubNetwork

private struct RouteMessageBuilder {
    var bytes: [UInt8] = []

    mutating func addInterface(index: Int, received: UInt64, sent: UInt64) {
        var header = if_msghdr2()
        header.ifm_msglen = UInt16(MemoryLayout<if_msghdr2>.size)
        header.ifm_type = UInt8(RTM_IFINFO2)
        header.ifm_index = UInt16(index)
        header.ifm_data.ifi_ibytes = received
        header.ifm_data.ifi_obytes = sent
        append(&header, length: MemoryLayout<if_msghdr2>.size)
    }

    mutating func addOther(type: Int32 = RTM_NEWADDR, length requested: Int) {
        let length = max(requested, 4)
        var messageLength = UInt16(length)
        append(&messageLength, length: MemoryLayout<UInt16>.size)
        bytes.append(UInt8(RTM_VERSION))
        bytes.append(UInt8(type))
        bytes.append(contentsOf: repeatElement(0xAB, count: length - 4))
    }

    mutating func addTruncatedInterface(declaredLength: Int) {
        var header = if_msghdr()
        header.ifm_msglen = UInt16(declaredLength)
        header.ifm_type = UInt8(RTM_IFINFO2)
        append(&header, length: MemoryLayout<if_msghdr>.size)
    }

    private mutating func append<T>(_ value: inout T, length: Int) {
        withUnsafeBytes(of: &value) { raw in
            bytes.append(contentsOf: raw.prefix(length))
        }
    }

    func parse(wantedIndex: Int? = nil) throws -> [Int: NetworkInterfaceCounters] {
        try bytes.withUnsafeBytes {
            try RouteMessageParser.parse($0, wantedIndex: wantedIndex)
        }
    }
}

@Suite("Route message parser")
struct RouteMessageParserTests {
    @Test("Reads 64-bit counters and filters by interface")
    func sixtyFourBitCounters() throws {
        var builder = RouteMessageBuilder()
        builder.addInterface(index: 4, received: 1, sent: 2)
        builder.addInterface(
            index: 11,
            received: UInt64(UInt32.max) + 10_000,
            sent: UInt64(UInt32.max) + 20_000
        )
        let parsed = try builder.parse(wantedIndex: 11)
        #expect(parsed.count == 1)
        #expect(parsed[11]?.receivedBytes == UInt64(UInt32.max) + 10_000)
        #expect(parsed[11]?.sentBytes == UInt64(UInt32.max) + 20_000)
    }

    @Test("Walks mixed records by each declared message length")
    func mixedUnalignedRecords() throws {
        var builder = RouteMessageBuilder()
        builder.addOther(length: 173)
        builder.addInterface(index: 4, received: 1_000, sent: 2_000)
        builder.addOther(length: 129)
        builder.addInterface(index: 11, received: 3_000, sent: 4_000)
        let parsed = try builder.parse()
        #expect(parsed[4] == NetworkInterfaceCounters(receivedBytes: 1_000, sentBytes: 2_000))
        #expect(parsed[11] == NetworkInterfaceCounters(receivedBytes: 3_000, sentBytes: 4_000))
    }

    @Test("Accepts short address and multicast records, including at the tail")
    func shortNonInterfaceRecords() throws {
        var builder = RouteMessageBuilder()
        builder.addOther(type: RTM_NEWADDR, length: 20)
        builder.addInterface(index: 11, received: 3_000, sent: 4_000)
        builder.addOther(type: RTM_NEWMADDR2, length: 56)
        let parsed = try builder.parse()
        #expect(parsed == [
            11: NetworkInterfaceCounters(receivedBytes: 3_000, sentBytes: 4_000),
        ])
    }

    @Test("Rejects a record whose body is truncated")
    func truncatedRecord() {
        var builder = RouteMessageBuilder()
        builder.addTruncatedInterface(declaredLength: 4_096)
        #expect(throws: NetworkTrafficSourceError.self) {
            try builder.parse()
        }
    }

    @Test("Rejects IFINFO2 records shorter than their own header")
    func shortDeclaredHeader() {
        var builder = RouteMessageBuilder()
        builder.addTruncatedInterface(declaredLength: MemoryLayout<if_msghdr>.size)
        builder.bytes.append(contentsOf: repeatElement(
            0,
            count: MemoryLayout<if_msghdr2>.size - MemoryLayout<if_msghdr>.size
        ))
        #expect(throws: NetworkTrafficSourceError.self) {
            try builder.parse()
        }
    }

    @Test("Rejects a zero length record instead of looping")
    func zeroLength() {
        var builder = RouteMessageBuilder()
        builder.addTruncatedInterface(declaredLength: 0)
        #expect(throws: NetworkTrafficSourceError.self) {
            try builder.parse()
        }
    }

    @Test("The production reader accepts the live route table")
    func liveRouteTableSmokeTest() async throws {
        let source = SystemNetworkCounterSource()
        let allTableSentinel = try await source.counters(forInterfaceIndex: 0)
        #expect(allTableSentinel == nil)

        let loopbackIndex = Int(if_nametoindex("lo0"))
        #expect(loopbackIndex > 0)
        let loopback = try await source.counters(forInterfaceIndex: loopbackIndex)
        #expect(loopback != nil)
    }
}
