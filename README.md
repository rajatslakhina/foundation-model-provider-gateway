# ProviderGatewayKit

Apple's WWDC26 session ["Bring an LLM provider to the Foundation Models framework"](https://developer.apple.com/videos/play/wwdc2026/339/) opened the on-device tool-calling/session API that used to be locked to Apple's own 3B-parameter model to *any* provider — a cloud API, an open-source model, a self-hosted fine-tune. That's a genuine platform decision, not a feature: once "which model answers this request" becomes pluggable, someone on the team has to own the layer that decides *which provider, in what order, with what fallback behavior* — the same call an Engineering Lead makes when choosing between three viable backends for any critical path.

**ProviderGatewayKit is that layer.** It's a small, dependency-free Swift package that routes chat/tool-calling requests across multiple LLM providers — on-device, cloud, self-hosted — with capability-aware ordering, circuit-breaker-based failover, transparent tool-call round-tripping, and context-budget-aware session state. It never links against a real inference framework (headless CI has no GPU or Neural Engine); instead it ships three *simulated* providers that model the real trade-offs (latency, cost, context window, tool-calling support, reliability) so the routing/session architecture can be built, tested, and demonstrated deterministically. A real backend plugs in by conforming to one protocol, `LLMProvider` — zero changes anywhere else.

## Why this matters

A single-provider integration is a tutorial. A provider-abstraction layer is what actually ships once a team has more than one backend to reason about — and "more than one" arrives fast: on-device for latency/cost/privacy, cloud for capability and context-window headroom, a self-hosted fine-tune for a domain-specific task. Without a shared abstraction, that's three copies of retry logic, three copies of streaming plumbing, and three different answers to "what happens when the on-device model can't handle this request." `ProviderGatewayKit` answers that once, with the failure modes made explicit instead of discovered in production:

- **What happens when a provider times out or rate-limits?** A per-provider circuit breaker trips after consecutive failures, so a known-bad provider is skipped instantly instead of adding latency to every subsequent request — then it's periodically re-probed (half-open) rather than either hammered or permanently abandoned.
- **What happens when a provider fails mid-stream, after it's already produced some text?** That output is buffered and discarded, never shown to the caller — see the trade-off note in `ProviderRouter.swift`.
- **What happens when a provider keeps requesting tool calls and never converges?** A round-trip ceiling throws a specific, catchable error (`RouterError.toolCallLimitExceeded`) instead of looping forever.
- **What happens when two user turns are submitted concurrently on the same session?** They're strictly serialized in submission order — see the ordering guarantee documented on `LLMSession`.
- **What happens when history grows past a provider's context window?** `ContextBudgetManager` trims the oldest turns first, but never the system prompt, even under extreme pressure.

## Design decision

**Protocol-oriented core, actor-isolated orchestration.** `LLMProvider`, `RoutingPolicy`, `LLMTool`, `SleepClock`, and `MonotonicClock` are all protocols so every axis of behavior — what backends exist, how they're preferred, what tools are callable, how time is simulated in tests — is independently swappable. The two pieces of actual mutable state that need correctness guarantees under concurrency (`ProviderRouter`'s circuit-breaker bookkeeping and `LLMSession`'s conversation history) are `actor`s, not classes with manual locking.

```
LLMSession (actor)
   │  owns transcript, applies ContextBudgetManager, serializes turns
   ▼
ProviderRouter (actor)
   │  orders capable providers via RoutingPolicy, drives tool-call round trips,
   │  owns one CircuitBreaker (actor) per provider
   ▼
LLMProvider (protocol) ── SimulatedOnDeviceProvider / SimulatedCloudProvider / SimulatedSelfHostedProvider
```

## Trade-offs and rejected alternatives

- **Buffer-then-forward streaming, not immediate forwarding.** A provider that fails mid-response may have already emitted several `.textDelta` chunks. This router buffers deltas per attempt and only forwards them once that attempt reaches a terminal event, discarding a failed attempt's output entirely. The alternative — stream immediately — was rejected because it can show the user a half-formed sentence from a provider that then fails over to a second provider starting fresh. The cost is a small added latency (a full attempt must finish or fail before anything renders); the benefit is that nothing user-visible is ever silently abandoned mid-sentence.
- **Character-count token estimation, not a real tokenizer.** Real tokenizers are provider-specific (and several are proprietary). A portable gateway layer that has to reason about *any* provider's context window can't hardcode one vendor's BPE table. `characters / 4` is a documented, conservative approximation used consistently for budgeting decisions — not represented as an exact count anywhere in the API.
- **Explicit FIFO turn-lock in `LLMSession`, not "it's an actor so it's fine."** Actor isolation alone does not serialize logical turns — `send(_:)` suspends at the network-bound `await router.send(...)` point, and without an explicit lock, a second concurrent `send` call would build its request against a transcript still missing the first call's reply. `LLMSession` uses a `CheckedContinuation`-based FIFO gate so turns complete in the order they were submitted, and `LLMSessionTests.testConcurrentSendsAreProcessedInSubmissionOrder` is a regression test for exactly this failure mode.
- **Circuit breaker per provider, not a single global breaker.** A global breaker would let one flaky provider's failures suppress traffic to healthy providers. Per-provider breakers (owned by `ProviderRouter`, one `CircuitBreaker` actor per registered provider) isolate the blast radius, at the cost of slightly more bookkeeping in the router's init.
- **Tool execution failures become `.tool` messages, not thrown errors.** A missing tool or a tool that throws still produces a valid conversational turn (`ToolRegistry.execute` converts both into `LLMToolResult.failure`) rather than aborting the whole exchange — the provider gets to react to "that tool failed" the same way it would react to any other tool result.

## Verification

`swift build` and `swift test` both pass in this repo's CI-equivalent (a headless Linux Swift 5.10.1 toolchain) — **34/34 tests pass**, covering: circuit breaker state transitions (closed → open → half-open → closed/re-open, using an injected fake clock so no test sleeps through a real reset window), provider fallback and aggregated-failure reporting, the tool-calling round-trip loop and its round-trip ceiling, the buffer-then-discard behavior for a failed attempt's partial output, `ContextBudgetManager`'s trimming edge cases (empty history, oversized system prompt, single oversized message), and `LLMSession`'s concurrent-turn-ordering and failed-turn-rollback guarantees.

`SimulatedOnDeviceProvider`, `SimulatedCloudProvider`, and `SimulatedSelfHostedProvider` are intentionally simplified stand-ins (no real model, no real network) — that's what makes the routing/session logic testable headlessly and deterministically. A real integration replaces them with types conforming to `LLMProvider` that wrap an actual on-device Foundation Models session, a cloud HTTP client, or an MLX-hosted endpoint; nothing else in this package needs to change.

## Requirements

Swift 5.10+ (package manifest targets tools-version 5.10 for broad toolchain compatibility; builds equally well under a Swift 6 toolchain). iOS 17+ / macOS 14+ as library platform minimums.

## Installation

Add this repository as a Swift Package dependency:

```swift
dependencies: [
    .package(url: "https://github.com/rajatslakhina/foundation-model-provider-gateway.git", branch: "main")
]
```

and add `"ProviderGatewayKit"` to your target's `dependencies`.

## Usage

```swift
import ProviderGatewayKit

let router = ProviderRouter(
    providers: [
        SimulatedOnDeviceProvider(),
        SimulatedCloudProvider()
    ]
)

let session = LLMSession(
    router: router,
    systemPrompt: "You are a concise, friendly assistant."
)

let reply = try await session.send("What's a good name for a routing layer?")
print(reply.text, "— answered by", reply.providerID)
```

Swap in your own `LLMProvider` conformance (wrapping a real on-device Foundation Models session, a cloud HTTP client, or an MLX-hosted endpoint) in place of the simulated providers above — nothing else in this snippet changes.

## Demo app

Demo app: **[foundation-model-provider-gateway-demo-app](https://github.com/rajatslakhina/foundation-model-provider-gateway-demo-app)** — a SwiftUI chat client built on this library, showing live provider routing (with a "which provider answered" badge on every reply), a tool-calling demo that forces the router down a tool-capable path, and a one-tap toggle to simulate a provider outage and watch automatic failover happen live.
