import Testing

import Artifact
import Connector
import Engine

@testable import WendyUpdate

// Ports `cmd/wendyos-update/main.go`'s `exitCode(err)`: every domain error
// type already conforms to `ExitCoded` (declared alongside each type, see
// `Sources/CLIError/ExitCoded.swift`'s doc comment) — `mapExit` is just the
// `(error as? any ExitCoded)?.exitCode ?? 1` glue main.go's type-switch
// chain becomes once every case already knows its own code.

@Suite("mapExit")
struct ExitCodeTests {
    @Test func nothingToCommitMapsToTwo() {
        #expect(mapExit(CommitError(.nothingToCommit)) == 2)
    }

    @Test func phaseFailedMapsToOne() {
        #expect(mapExit(CommitError(.phaseFailed("pending update is marked failed"))) == 1)
    }

    @Test func platformVerifyMapsToFour() {
        #expect(mapExit(CommitError(.platformVerify("firmware fallback"))) == 4)
    }

    @Test func artifactErrorMapsToThree() {
        #expect(mapExit(ArtifactError.invalidManifest("bad manifest")) == 3)
        #expect(mapExit(ArtifactError.sha256Mismatch("mismatch")) == 3)
    }

    @Test func engineRejectedMapsToThree() {
        #expect(mapExit(EngineError.rejected("incompatible device")) == 3)
    }

    @Test func engineOtherCasesMapToOne() {
        #expect(mapExit(EngineError.updateInFlight(phase: "written", artifact: "x")) == 1)
        #expect(mapExit(EngineError.deviceType("no BOARD= line")) == 1)
    }

    @Test func healthHookFailureMapsToFour() {
        #expect(mapExit(HookError(phase: HookHealth, hook: "10-check", underlying: "exit status 1")) == 4)
    }

    @Test func preInstallHookFailureMapsToOne() {
        #expect(mapExit(HookError(phase: HookPreInstall, hook: "10-check", underlying: "exit status 1")) == 1)
    }

    @Test func postInstallHookFailureMapsToOne() {
        #expect(mapExit(HookError(phase: HookPostInstall, hook: "10-check", underlying: "exit status 1")) == 1)
    }

    @Test func connectorErrorMapsToOne() {
        #expect(mapExit(ConnectorError.noneDetected(have: ["tegrauefi", "ubootenv"])) == 1)
        #expect(mapExit(ConnectorError.notBuiltIn(name: "foo", have: ["tegrauefi"])) == 1)
        #expect(mapExit(ConnectorError.ambiguous(["tegrauefi", "ubootenv"])) == 1)
    }

    @Test func rollbackAndSwitchErrorsMapToOne() {
        #expect(mapExit(RollbackError(message: "nothing to roll back")) == 1)
        #expect(mapExit(SwitchError(message: "already running slot A")) == 1)
    }

    @Test func unknownErrorDefaultsToOne() {
        struct Opaque: Error {}
        #expect(mapExit(Opaque()) == 1)
    }
}

@Suite("isNothingToCommit")
struct IsNothingToCommitTests {
    @Test func trueOnlyForTheNothingToCommitKind() {
        #expect(isNothingToCommit(CommitError(.nothingToCommit)))
    }

    @Test func falseForEveryOtherCommitErrorKind() {
        #expect(!isNothingToCommit(CommitError(.phaseFailed("x"))))
        #expect(!isNothingToCommit(CommitError(.platformVerify("x"))))
    }

    @Test func falseForUnrelatedErrorTypes() {
        #expect(!isNothingToCommit(EngineError.rejected("x")))
        #expect(!isNothingToCommit(ArtifactError.invalidManifest("x")))
    }
}
