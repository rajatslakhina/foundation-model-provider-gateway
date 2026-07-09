import XCTest
@testable import ProviderGatewayKit

final class CapabilityAwareRoutingPolicyTests: XCTestCase {
    private func makeProvider(
        id: String,
        locality: ProviderLocality,
        costTier: ProviderCostTier
    ) -> ScriptedProvider {
        ScriptedProvider(
            identifier: ProviderIdentifier(id),
            capabilities: ProviderCapabilities(
                supportsToolCalling: true,
                supportsStreaming: true,
                maxContextTokens: 10_000,
                costTier: costTier,
                locality: locality
            ),
            script: []
        )
    }

    private let sampleRequest = LLMRequest(messages: [LLMMessage(role: .user, content: "hi")])

    func testOnDeviceIsPreferredOverNetwork() {
        let onDevice = makeProvider(id: "on-device", locality: .onDevice, costTier: .free)
        let cloud = makeProvider(id: "cloud", locality: .network, costTier: .free)
        let policy = CapabilityAwareRoutingPolicy()

        let ordered = policy.order(candidates: [cloud, onDevice], for: sampleRequest)
        XCTAssertEqual(ordered.map(\.identifier), [onDevice.identifier, cloud.identifier])
    }

    func testCheaperCostTierPreferredWithinSameLocality() {
        let cheap = makeProvider(id: "cheap", locality: .network, costTier: .low)
        let expensive = makeProvider(id: "expensive", locality: .network, costTier: .high)
        let policy = CapabilityAwareRoutingPolicy()

        let ordered = policy.order(candidates: [expensive, cheap], for: sampleRequest)
        XCTAssertEqual(ordered.map(\.identifier), [cheap.identifier, expensive.identifier])
    }

    func testIdentifierIsStableTiebreaker() {
        let a = makeProvider(id: "aaa", locality: .network, costTier: .low)
        let b = makeProvider(id: "bbb", locality: .network, costTier: .low)
        let policy = CapabilityAwareRoutingPolicy()

        let ordered = policy.order(candidates: [b, a], for: sampleRequest)
        XCTAssertEqual(ordered.map(\.identifier), [a.identifier, b.identifier])
    }

    func testEmptyCandidatesReturnsEmpty() {
        let policy = CapabilityAwareRoutingPolicy()
        XCTAssertTrue(policy.order(candidates: [], for: sampleRequest).isEmpty)
    }
}
