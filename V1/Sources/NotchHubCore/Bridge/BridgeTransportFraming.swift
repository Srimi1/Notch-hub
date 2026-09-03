import Foundation

public enum BridgeTransportFraming {
    public static func framedData<T: Encodable>(
        for value: T,
        maximumBytes: Int = BridgeTransportConstants.maximumFrameBytes
    ) throws -> Data {
        let body = try encodedBody(value, maximumBytes: maximumBytes)
        let count = UInt32(body.count)
        let prefix = Data([
            UInt8((count >> 24) & 0xFF),
            UInt8((count >> 16) & 0xFF),
            UInt8((count >> 8) & 0xFF),
            UInt8(count & 0xFF),
        ])
        return prefix + body
    }

    public static func decodedValue<T: Decodable>(
        _ type: T.Type,
        fromFramedData data: Data,
        maximumBytes: Int = BridgeTransportConstants.maximumFrameBytes
    ) throws -> T {
        guard data.count >= 4 else {
            throw BridgeTransportError.malformedFrame
        }
        let length = try decodedLength(Data(data.prefix(4)), maximumBytes: maximumBytes)
        guard data.count >= 4 + length else {
            throw BridgeTransportError.malformedFrame
        }
        guard data.count == 4 + length else {
            throw BridgeTransportError.trailingFrameData
        }
        return try decodedBody(type, from: Data(data.dropFirst(4)), maximumBytes: maximumBytes)
    }

    static func encodedBody<T: Encodable>(_ value: T, maximumBytes: Int) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data: Data
        do {
            data = try encoder.encode(value)
        } catch {
            throw BridgeTransportError.malformedFrame
        }
        guard data.count <= maximumBytes, data.count <= Int(UInt32.max) else {
            throw BridgeTransportError.oversizedFrame(limit: maximumBytes)
        }
        return data
    }

    static func decodedLength(_ prefix: Data, maximumBytes: Int) throws -> Int {
        guard prefix.count == 4 else {
            throw BridgeTransportError.malformedFrame
        }
        let bytes = [UInt8](prefix)
        let value = UInt32(bytes[0]) << 24
            | UInt32(bytes[1]) << 16
            | UInt32(bytes[2]) << 8
            | UInt32(bytes[3])
        let length = Int(value)
        guard length > 0, length <= maximumBytes else {
            throw BridgeTransportError.oversizedFrame(limit: maximumBytes)
        }
        return length
    }

    static func decodedBody<T: Decodable>(
        _ type: T.Type,
        from data: Data,
        maximumBytes: Int
    ) throws -> T {
        guard !data.isEmpty, data.count <= maximumBytes else {
            throw BridgeTransportError.oversizedFrame(limit: maximumBytes)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(type, from: data)
        } catch {
            throw BridgeTransportError.malformedFrame
        }
    }

    static func decodedRequestBody(_ data: Data) throws -> BridgeTransportRequestFrame {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw BridgeTransportError.malformedFrame
        }
        guard let root = object as? [String: Any], let requestObject = root["request"] else {
            throw BridgeTransportError.malformedFrame
        }
        let requestData: Data
        do {
            requestData = try JSONSerialization.data(withJSONObject: requestObject, options: [.sortedKeys])
            _ = try BridgeCodec.decodeRequest(requestData)
        } catch let error as BridgeProtocolError {
            throw error
        } catch {
            throw BridgeTransportError.malformedFrame
        }
        return try decodedBody(
            BridgeTransportRequestFrame.self,
            from: data,
            maximumBytes: BridgeTransportConstants.maximumFrameBytes
        )
    }
}
