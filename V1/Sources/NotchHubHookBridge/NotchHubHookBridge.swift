import Darwin
import Foundation
import NotchHubCore

@main
enum NotchHubHookBridge {
    static func main() async {
        let invocation: BridgeHookInvocation
        do {
            invocation = try BridgeHookInvocation.parse(arguments: Array(CommandLine.arguments.dropFirst()))
        } catch {
            return
        }

        let input: Data
        do {
            input = try BridgeBoundedInput.read(from: .standardInput)
        } catch {
            return
        }

        let request: BridgeRequestEnvelope
        do {
            let nonce = try SecureBridgeNonceGenerator().freshNonce()
            request = try BridgeProviderHookCodec.request(
                from: input,
                invocation: invocation,
                now: Date(),
                requestNonce: nonce
            )
        } catch {
            return
        }

        let client = BridgeUnixSocketClient()
        let fallbackOutput = BridgeProviderHookCodec.statusLineOutput(for: request, invocation: invocation)
        do {
            let timeout = invocation.event == .permissionRequest
                ? BridgeTransportConstants.maximumDeadlineMilliseconds
                : 1_000
            let response = try await client.send(request, timeoutMilliseconds: timeout)
            if let output = try BridgeProviderHookCodec.providerOutput(
                for: response,
                request: request,
                invocation: invocation
            ) {
                write(output)
            }
        } catch {
            if let fallbackOutput {
                write(fallbackOutput)
            }
            return
        }
    }

    private static func write(_ output: Data) {
        do {
            var terminatedOutput = output
            terminatedOutput.append(0x0A)
            try FileHandle.standardOutput.write(contentsOf: terminatedOutput)
        } catch {
            _ = fputs("NotchHubHookBridge: unable to write provider decision\n", stderr)
        }
    }
}
