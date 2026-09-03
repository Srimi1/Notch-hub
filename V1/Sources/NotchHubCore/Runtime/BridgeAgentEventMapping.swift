import CryptoKit
import Foundation
import NotchHubBridge

extension BridgeAgentEventCoordinator {
    func scopedIdentifier(provider: ProviderID, value: String) -> String {
        var scopedData = Data(provider.rawValue.utf8)
        scopedData.append(0)
        scopedData.append(Data(value.utf8))
        let digest = SHA256.hash(data: scopedData).map { String(format: "%02x", $0) }.joined()
        return "\(provider.rawValue):\(digest)"
    }

    func actionCategory(_ category: BridgeActionCategory) -> ApprovalActionCategory {
        switch category {
        case .fileRead, .fileWrite: .fileChange
        case .processExecution: .command
        case .networkAccess: .network
        case .versionControl, .systemChange: .tool
        case .unknown: .unknown
        }
    }

    func approvalRisk(_ risk: BridgeRiskLevel) -> ApprovalRisk {
        switch risk {
        case .low: .low
        case .elevated: .moderate
        case .high: .high
        }
    }
}
