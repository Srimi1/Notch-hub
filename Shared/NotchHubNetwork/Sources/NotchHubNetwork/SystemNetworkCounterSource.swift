// Adapted and modified from Internet-speed-reader at commit c5e0f627.
// Licensed under Apache-2.0; see LICENSE and UPSTREAM.md in this package.

import Darwin
import Foundation

public struct SystemNetworkCounterSource: NetworkCounterSource {
    public init() {}

    public func counters(
        forInterfaceIndex index: Int
    ) async throws -> NetworkInterfaceCounters? {
        try read(index: index)[index]
    }

    private func read(index: Int) throws -> [Int: NetworkInterfaceCounters] {
        guard index >= 0, let routeIndex = Int32(exactly: index) else {
            throw NetworkTrafficSourceError.invalidInterfaceIndex(index)
        }
        var managementInformationBase: [Int32] = [
            CTL_NET,
            PF_ROUTE,
            0,
            0,
            NET_RT_IFLIST2,
            routeIndex,
        ]
        var size = try routeTableSize(managementInformationBase: &managementInformationBase)
        let buffer = try routeTableBuffer(
            managementInformationBase: &managementInformationBase,
            size: &size
        )
        return try parse(buffer: buffer, size: size, wantedIndex: index)
    }

    private func routeTableBuffer(
        managementInformationBase: inout [Int32],
        size: inout Int
    ) throws -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: size)
        var readResult = read(
            managementInformationBase: &managementInformationBase,
            into: &buffer,
            size: &size
        )
        if readResult.status != 0, readResult.errorCode == ENOMEM {
            size = try routeTableSize(
                managementInformationBase: &managementInformationBase,
                operation: "sysctl(NET_RT_IFLIST2) retry size"
            )
            buffer = [UInt8](repeating: 0, count: size)
            readResult = read(
                managementInformationBase: &managementInformationBase,
                into: &buffer,
                size: &size
            )
        }
        guard readResult.status == 0 else {
            throw NetworkTrafficSourceError.systemCall(
                operation: "sysctl(NET_RT_IFLIST2) read",
                code: readResult.errorCode
            )
        }
        return buffer
    }

    private func routeTableSize(
        managementInformationBase: inout [Int32],
        operation: String = "sysctl(NET_RT_IFLIST2) size"
    ) throws -> Int {
        var size = 0
        let result = sysctlResult(
            managementInformationBase: &managementInformationBase,
            destination: nil,
            size: &size
        )
        guard result.status == 0 else {
            throw NetworkTrafficSourceError.systemCall(
                operation: operation,
                code: result.errorCode
            )
        }
        guard size > 0 else {
            throw NetworkTrafficSourceError.emptyRouteTable
        }
        return size
    }

    private func parse(
        buffer: [UInt8],
        size: Int,
        wantedIndex: Int
    ) throws -> [Int: NetworkInterfaceCounters] {
        guard size > 0, size <= buffer.count else {
            throw NetworkTrafficSourceError.malformedRouteMessage(
                offset: 0,
                declaredLength: size,
                requiredLength: 1,
                bufferLength: buffer.count
            )
        }

        return try buffer.withUnsafeBytes { rawBuffer in
            let bytes = UnsafeRawBufferPointer(rebasing: rawBuffer[..<size])
            return try RouteMessageParser.parse(bytes, wantedIndex: wantedIndex)
        }
    }

    private func read(
        managementInformationBase: inout [Int32],
        into buffer: inout [UInt8],
        size: inout Int
    ) -> (status: Int32, errorCode: Int32) {
        buffer.withUnsafeMutableBytes { rawBuffer in
            sysctlResult(
                managementInformationBase: &managementInformationBase,
                destination: rawBuffer.baseAddress,
                size: &size
            )
        }
    }

    private func sysctlResult(
        managementInformationBase: inout [Int32],
        destination: UnsafeMutableRawPointer?,
        size: inout Int
    ) -> (status: Int32, errorCode: Int32) {
        let status = sysctl(
            &managementInformationBase,
            u_int(managementInformationBase.count),
            destination,
            &size,
            nil,
            0
        )
        return (status, status == 0 ? 0 : errno)
    }
}
