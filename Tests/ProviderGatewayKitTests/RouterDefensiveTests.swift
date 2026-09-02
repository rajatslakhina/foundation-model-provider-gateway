import XCTest
@testable import ProviderGatewayKit

/// A policy that hands the router a provider the router has never heard of.
///
/// This is not a contrived shape. `RoutingPolicy` is public and its whole point is that a
/// host app can supply its own ordering; nothing in the protocol stops an implementation
/// returning a candidate the router did not register, and the router is right to treat
/// that as unavailable rather than force-unwrapping a missing circuit breaker.
private struct InjectingPolicy: RoutingPolicy {
    let injected: any LLMProvider

    func order(candidates: [any LLMProvider], for request: LLMRequest) -> [any LLMProvider] {
        [injected] + candidates
    }
}

private let openCapabilities = ProviderCapabilities(
    supportsToolCalling: true,
    supportsStreaming: true,
    maxContextTokens: 10_000,
    costTier: .low,
    locality: .network
)

/// The router's two defensive paths, both reachable through the public API.
final class RouterDefensiveTests: XCTestCase {
    private let request = LLMRequest(messages: [LLMMessage(role: .user, content: "hi")])

    func testAProviderWithNoRegisteredBreakerIsTreatedAsUnavailable() async {
        let registered = ScriptedProvider(
            identifier: ProviderIdentifier("registered"),
            capabilities: openCapabilities,
            script: [.failure(ProviderError.timeout)]
        )
        let smuggled = ScriptedProvider(
            identifier: ProviderIdentifier("smuggled"),
            capabilities: openCapabilities,
            script: [.events([.completed(
                LLMResponse(text: "should never be reached", finishReason: .stop, providerID: ProviderIdentifier("smuggled"))
            )])]
        )
        let router = ProviderRouter(
            providers: [registered],
            policy: InjectingPolicy(injected: smuggled)
        )

        do {
            _ = try await router.send(request)
            XCTFail("expected every candidate to fail")
        } catch let error as RouterError {
            guard case .allProvidersFailed(let failures) = error else {
                return XCTFail("expected allProvidersFailed, got \(error)")
            }
            XCTAssertEqual(failures[ProviderIdentifier("smuggled")], "no circuit breaker registered")
            XCTAssertNotNil(failures[ProviderIdentifier("registered")])
        } catch {
            XCTFail("expected a RouterError, got \(error)")
        }

        let smuggledCalls = await smuggled.callCount
        XCTAssertEqual(smuggledCalls, 0, "an unregistered provider must never be invoked")
    }

    /// A provider that finishes its stream having yielded only text is not a provider
    /// that answered. The router has to treat the missing terminal event as a failure,
    /// or a caller would get an empty completion built from nothing.
    func testAStreamThatEndsWithoutATerminalEventIsAFailure() async {
        let truncating = ScriptedProvider(
            identifier: ProviderIdentifier("truncating"),
            capabilities: openCapabilities,
            script: [.events([.textDelta("half an ans")])]
        )
        let router = ProviderRouter(providers: [truncating])

        do {
            _ = try await router.send(request)
            XCTFail("expected a truncated stream to fail")
        } catch let error as RouterError {
            guard case .allProvidersFailed(let failures) = error else {
                return XCTFail("expected allProvidersFailed, got \(error)")
            }
            let reason = failures[ProviderIdentifier("truncating")] ?? ""
            XCTAssertTrue(reason.contains("without a terminal event"), "got \(reason)")
        } catch {
            XCTFail("expected a RouterError, got \(error)")
        }
    }

    /// The partial text from a truncated attempt must not reach the caller — the same
    /// rule the router applies to an attempt that throws.
    func testTruncatedOutputIsNotForwardedToTheCaller() async {
        let truncating = ScriptedProvider(
            identifier: ProviderIdentifier("truncating"),
            capabilities: openCapabilities,
            script: [.events([.textDelta("half an ans")])]
        )
        let router = ProviderRouter(providers: [truncating])

        var seen: [LLMStreamEvent] = []
        do {
            for try await event in await router.stream(request) {
                seen.append(event)
            }
            XCTFail("expected the stream to throw")
        } catch {
            XCTAssertTrue(seen.isEmpty, "a failed attempt's partial output leaked: \(seen)")
        }
    }
}
