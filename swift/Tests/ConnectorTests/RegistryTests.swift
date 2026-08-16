import Testing

import Connector

/// Minimal fake `Connector` used only to exercise `ConnectorRegistry.select`
/// — its methods are never called by the registry, so they all just throw a
/// sentinel error if that assumption is ever wrong.
private final class FakeConnector: Connector {
    let name: String
    init(name: String) { self.name = name }

    func currentSlot() throws -> Slot { .a }
    func partition(for s: Slot) throws -> String { "" }
    func prepareTarget(_ s: Slot) throws {}
    func swapSlot(_ s: Slot, stagePlatformUpdate: Bool) throws {}
    func bootIsCompromised() throws -> Bool { false }
    func verifyPlatformUpdate(bootloaderUpdate: Bool) throws {}
    func abortPlatformUpdate() throws {}
    func markGood() throws {}
    func diagnostics(verbose: Bool) -> [String: String] { [:] }
    func slotStatus(_ s: Slot) -> SlotStatus { SlotStatus() }
    func systemStatus() -> [KV] { [] }
}

private func factory(_ name: String, detect: @escaping @Sendable () -> Bool) -> ConnectorFactory {
    ConnectorFactory(name: name, make: { FakeConnector(name: name) }, detect: detect)
}

@Suite("Slot")
struct SlotTests {
    @Test func otherFlips() {
        #expect(Slot.a.other == .b)
        #expect(Slot.b.other == .a)
    }

    @Test func description() {
        #expect(Slot.a.description == "A")
        #expect(Slot.b.description == "B")
    }
}

@Suite("ConnectorRegistry.select")
struct ConnectorRegistrySelectTests {
    @Test func explicitNameSelectsIt() throws {
        let factories = [
            factory("tegrauefi", detect: { false }),
            factory("ubootenv", detect: { false }),
        ]
        let selected = try ConnectorRegistry.select(explicit: "ubootenv", from: factories)
        #expect(selected.name == "ubootenv")
    }

    @Test func explicitUnknownNameThrowsNotBuiltIn() {
        let factories = [
            factory("tegrauefi", detect: { false }),
            factory("ubootenv", detect: { false }),
        ]
        #expect(throws: ConnectorError.notBuiltIn(name: "bogus", have: ["tegrauefi", "ubootenv"])) {
            try ConnectorRegistry.select(explicit: "bogus", from: factories)
        }
    }

    @Test func exactlyOneDetectSelectsIt() throws {
        let factories = [
            factory("tegrauefi", detect: { true }),
            factory("ubootenv", detect: { false }),
        ]
        let selected = try ConnectorRegistry.select(explicit: nil, from: factories)
        #expect(selected.name == "tegrauefi")
    }

    @Test func zeroDetectThrowsNoneDetected() {
        let factories = [
            factory("tegrauefi", detect: { false }),
            factory("ubootenv", detect: { false }),
        ]
        #expect(throws: ConnectorError.noneDetected(have: ["tegrauefi", "ubootenv"])) {
            try ConnectorRegistry.select(explicit: nil, from: factories)
        }
    }

    @Test func twoDetectThrowsAmbiguousSorted() {
        let factories = [
            factory("zeta", detect: { true }),
            factory("alpha", detect: { true }),
        ]
        #expect(throws: ConnectorError.ambiguous(["alpha", "zeta"])) {
            try ConnectorRegistry.select(explicit: nil, from: factories)
        }
    }
}
