import Testing
@testable import NotchHubNetwork

private func networkInterface(
    _ name: String,
    _ index: Int,
    _ kind: NetworkPathSnapshot.Interface.Kind,
    used: Bool = false
) -> NetworkPathSnapshot.Interface {
    NetworkPathSnapshot.Interface(name: name, index: index, kind: kind, isUsedByPath: used)
}

@Suite("Active network interface selection")
struct NetworkPathTests {
    @Test("Duplicate address-family entries are ignored")
    func duplicateInterfaces() {
        let selected = NetworkActiveInterfaceSelector.select(from: [
            networkInterface("en0", 11, .wifi),
            networkInterface("en0", 11, .wifi),
        ])
        #expect(selected?.name == "en0")
    }

    @Test("A physical interface wins over a VPN to avoid double counting")
    func physicalBeforeTunnel() {
        let selected = NetworkActiveInterfaceSelector.select(from: [
            networkInterface("utun4", 21, .tunnel, used: true),
            networkInterface("en0", 11, .wifi),
        ])
        #expect(selected?.name == "en0")
    }

    @Test("A tunnel is used when it is the only viable interface")
    func tunnelOnly() {
        let selected = NetworkActiveInterfaceSelector.select(from: [
            networkInterface("utun4", 21, .tunnel),
        ])
        #expect(selected?.name == "utun4")
    }

    @Test("The in-use physical adapter wins and same-type ties keep path order")
    func deterministicActiveAdapter() {
        let selected = NetworkActiveInterfaceSelector.select(from: [
            networkInterface("en5", 14, .wiredEthernet, used: true),
            networkInterface("en6", 15, .wiredEthernet, used: true),
            networkInterface("en0", 11, .wifi),
        ])
        #expect(selected?.name == "en5")
    }

    @Test("Loopback and Apple peer-to-peer adapters are excluded")
    func excludedInterfaces() {
        let selected = NetworkActiveInterfaceSelector.select(from: [
            networkInterface("lo0", 1, .loopback),
            networkInterface("awdl0", 15, .other),
            networkInterface("llw0", 16, .other),
        ])
        #expect(selected == nil)
    }
}
