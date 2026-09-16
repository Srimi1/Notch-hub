// Adapted and modified from Internet-speed-reader at commit c5e0f627.
// Licensed under Apache-2.0; see LICENSE and UPSTREAM.md in this package.

import Darwin
import Foundation

enum RouteMessageParser {
    static func parse(
        _ buffer: UnsafeRawBufferPointer,
        wantedIndex: Int? = nil
    ) throws -> [Int: NetworkInterfaceCounters] {
        var result: [Int: NetworkInterfaceCounters] = [:]
        let commonHeaderSize = 4
        let interfaceHeaderSize = MemoryLayout<if_msghdr2>.size
        var offset = 0

        while offset < buffer.count {
            guard buffer.count - offset >= commonHeaderSize else {
                throw malformedRecord(
                    offset: offset,
                    declaredLength: buffer.count - offset,
                    requiredLength: commonHeaderSize,
                    bufferLength: buffer.count
                )
            }
            let declaredLength = Int(buffer.loadUnaligned(
                fromByteOffset: offset,
                as: UInt16.self
            ))
            try validateRecord(
                offset: offset,
                declaredLength: declaredLength,
                requiredLength: commonHeaderSize,
                bufferLength: buffer.count
            )

            let messageType = buffer.loadUnaligned(
                fromByteOffset: offset + 3,
                as: UInt8.self
            )
            if Int32(messageType) == RTM_IFINFO2 {
                try validateRecord(
                    offset: offset,
                    declaredLength: declaredLength,
                    requiredLength: interfaceHeaderSize,
                    bufferLength: buffer.count
                )
                let interfaceHeader = buffer.loadUnaligned(
                    fromByteOffset: offset,
                    as: if_msghdr2.self
                )
                let index = Int(interfaceHeader.ifm_index)
                if wantedIndex == nil || wantedIndex == index {
                    result[index] = NetworkInterfaceCounters(
                        receivedBytes: interfaceHeader.ifm_data.ifi_ibytes,
                        sentBytes: interfaceHeader.ifm_data.ifi_obytes
                    )
                }
            }
            offset += declaredLength
        }
        return result
    }

    private static func validateRecord(
        offset: Int,
        declaredLength: Int,
        requiredLength: Int,
        bufferLength: Int
    ) throws {
        guard declaredLength >= requiredLength,
              declaredLength <= bufferLength - offset else {
            throw malformedRecord(
                offset: offset,
                declaredLength: declaredLength,
                requiredLength: requiredLength,
                bufferLength: bufferLength
            )
        }
    }

    private static func malformedRecord(
        offset: Int,
        declaredLength: Int,
        requiredLength: Int,
        bufferLength: Int
    ) -> NetworkTrafficSourceError {
        .malformedRouteMessage(
            offset: offset,
            declaredLength: declaredLength,
            requiredLength: requiredLength,
            bufferLength: bufferLength
        )
    }
}
