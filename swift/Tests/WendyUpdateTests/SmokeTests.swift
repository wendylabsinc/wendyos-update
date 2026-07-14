import Testing
@testable import WendyUpdate

@Test func toolVersionIsSemver() {
    #expect(WendyUpdate.version == "0.1.0-dev")
}
