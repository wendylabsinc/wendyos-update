import Testing

import Connector
import Engine
import Model

@testable import WendyUpdate

// Ports the stdout JSON event shapes from `cmd/wendyos-update/main.go`'s
// `cmdInstall`/`cmdSwitch`/`cmdRollback`/`emitProgress`. Each event is a
// `map[string]any` on the Go side, and Go's `encoding/json` sorts a map's
// keys ALPHABETICALLY when marshaling — regardless of the literal's source
// order — so the expected byte strings below are in alphabetical key
// order, not call-site order.

@Suite("stdout event JSON shapes")
struct OutputEventShapeTests {
    @Test func installDoneEvent() {
        let result = InstallResult(
            artifactName: "wendyos-image-jetson-agx-thor-devkit-nvme-wendyos-0.16.0",
            artifactVersion: "0.16.0",
            targetSlot: .b,
            bootloaderUpdate: true
        )

        let bytes = JSONCodec.encodeCompact(makeInstallDoneJSON(result))

        #expect(
            String(decoding: bytes, as: UTF8.self) ==
                #"{"artifact_name":"wendyos-image-jetson-agx-thor-devkit-nvme-wendyos-0.16.0","artifact_version":"0.16.0","bootloader_update":true,"percent":100,"phase":"done","reboot_required":true,"target_slot":"B"}"#
        )
    }

    @Test func switchEvent() {
        let bytes = JSONCodec.encodeCompact(makeSwitchJSON(target: .a))

        #expect(
            String(decoding: bytes, as: UTF8.self) ==
                #"{"phase":"switch","reboot_required":true,"target_slot":"A"}"#
        )
    }

    @Test func rollbackEvent() {
        let result = RollbackResult(originSlot: .a, rebootRequired: false)

        let bytes = JSONCodec.encodeCompact(makeRollbackJSON(result))

        #expect(
            String(decoding: bytes, as: UTF8.self) ==
                #"{"origin_slot":"A","phase":"rollback","reboot_required":false}"#
        )
    }

    @Test func progressEventWithDeterminatePercent() {
        let bytes = JSONCodec.encodeCompact(makeProgressJSON(phase: "write", percent: 42))

        #expect(String(decoding: bytes, as: UTF8.self) == #"{"percent":42,"phase":"write"}"#)
    }

    @Test func progressEventWithIndeterminatePercent() {
        let bytes = JSONCodec.encodeCompact(makeProgressJSON(phase: "download", percent: -1))

        #expect(String(decoding: bytes, as: UTF8.self) == #"{"percent":-1,"phase":"download"}"#)
    }
}

@Suite("TTY suppression")
struct OutputTTYSuppressionTests {
    @Test func emitEventIsSuppressedOnATTYStdout() {
        var written: [[UInt8]] = []

        emitEvent(makeSwitchJSON(target: .a), stdoutIsTTY: true) { written.append($0) }

        #expect(written.isEmpty)
    }

    @Test func emitEventWritesWhenStdoutIsNotATTY() {
        var written: [[UInt8]] = []

        emitEvent(makeSwitchJSON(target: .a), stdoutIsTTY: false) { written.append($0) }

        #expect(written.count == 1)
    }

    @Test func emitProgressJSONIsSuppressedOnATTYStdout() {
        var written: [[UInt8]] = []

        emitProgressJSON(phase: "write", percent: 10, stdoutIsTTY: true) { written.append($0) }

        #expect(written.isEmpty)
    }

    @Test func emitProgressJSONWritesWhenStdoutIsNotATTY() {
        var written: [[UInt8]] = []

        emitProgressJSON(phase: "write", percent: 10, stdoutIsTTY: false) { written.append($0) }

        #expect(written.count == 1)
        #expect(String(decoding: written[0], as: UTF8.self) == #"{"percent":10,"phase":"write"}"#)
    }
}

@Suite("status --json shape")
struct StatusJSONShapeTests {
    @Test func minimalStatusOmitsEmptyCollectionsAndNilPending() {
        let info = StatusInfo(
            connector: "tegrauefi",
            currentSlot: "A",
            slots: [],
            system: [],
            pending: nil,
            diagnostics: [:]
        )

        let bytes = JSONCodec.encodeCompact(makeStatusJSON(info))

        #expect(String(decoding: bytes, as: UTF8.self) == #"{"connector":"tegrauefi","current_slot":"A"}"#)
    }

    @Test func slotStateOmitsEmptyOptionalFields() {
        var slot = SlotState(slot: "A", booted: true)
        slot.partition = "/dev/nvme0n1p1"
        // distro/kernel/rootfsHealth/retries/note left empty.

        let bytes = JSONCodec.encodeCompact(makeSlotStateJSON(slot))

        #expect(String(decoding: bytes, as: UTF8.self) == #"{"slot":"A","booted":true,"partition":"/dev/nvme0n1p1"}"#)
    }

    @Test func diagnosticsKeysAreSortedAlphabetically() {
        let info = StatusInfo(
            connector: "tegrauefi",
            currentSlot: "A",
            slots: [],
            system: [],
            pending: nil,
            diagnostics: ["zeta": "1", "alpha": "2"]
        )

        let bytes = JSONCodec.encodeCompact(makeStatusJSON(info))

        #expect(
            String(decoding: bytes, as: UTF8.self) ==
                #"{"connector":"tegrauefi","current_slot":"A","diagnostics":{"alpha":"2","zeta":"1"}}"#
        )
    }
}
