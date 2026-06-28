package engine

import (
	"archive/tar"
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"testing"

	"github.com/klauspost/compress/zstd"
	"github.com/wendylabsinc/wendyos-update/internal/artifact"
	"github.com/wendylabsinc/wendyos-update/internal/connector"
)

// --- fake connector ---

type fakeConn struct {
	cur connector.Slot
	dev string // PartitionFor result for the non-current slot

	prepared  []connector.Slot
	swapped   []connector.Slot
	swapStage []bool
	markGood  int
	aborted   int

	failSwap    bool
	failPrepare bool
	compromised bool
	verifyErr   error
}

func (f *fakeConn) Name() string                         { return "fake" }
func (f *fakeConn) CurrentSlot() (connector.Slot, error) { return f.cur, nil }
func (f *fakeConn) PartitionFor(s connector.Slot) (string, error) {
	return f.dev, nil
}
func (f *fakeConn) PrepareTarget(s connector.Slot) error {
	if f.failPrepare {
		return errors.New("prepare failed")
	}
	f.prepared = append(f.prepared, s)
	return nil
}
func (f *fakeConn) SwapSlot(s connector.Slot, stagePlatformUpdate bool) error {
	if f.failSwap {
		return errors.New("swap failed")
	}
	f.swapped = append(f.swapped, s)
	f.swapStage = append(f.swapStage, stagePlatformUpdate)
	return nil
}
func (f *fakeConn) BootIsCompromised() (bool, error)           { return f.compromised, nil }
func (f *fakeConn) VerifyPlatformUpdate(blUpdate bool) error   { return f.verifyErr }
func (f *fakeConn) AbortPlatformUpdate() error                 { f.aborted++; return nil }
func (f *fakeConn) MarkGood() error                            { f.markGood++; return nil }
func (f *fakeConn) Diagnostics(verbose bool) map[string]string { return nil }
func (f *fakeConn) SlotStatus(s connector.Slot) connector.SlotStatus {
	return connector.SlotStatus{}
}
func (f *fakeConn) SystemStatus() []connector.KV { return nil }

// --- Switch ---

func TestSwitch(t *testing.T) {
	f := &fakeConn{cur: connector.SlotA}
	e := testEngine(t, f)
	if err := e.Switch(connector.SlotB); err != nil {
		t.Fatalf("switch: %v", err)
	}
	if len(f.prepared) != 1 || f.prepared[0] != connector.SlotB {
		t.Fatalf("expected prepare B, got %v", f.prepared)
	}
	if len(f.swapped) != 1 || f.swapped[0] != connector.SlotB || f.swapStage[0] {
		t.Fatalf("expected non-staging swap to B, got swapped=%v stage=%v", f.swapped, f.swapStage)
	}
}

func TestSwitchRefusesWhenPending(t *testing.T) {
	f := &fakeConn{cur: connector.SlotA}
	e := testEngine(t, f)
	if err := e.SaveState(&State{Schema: 1, Phase: PhaseSwapped, TargetSlot: int(connector.SlotB), ArtifactName: "x"}); err != nil {
		t.Fatal(err)
	}
	if err := e.Switch(connector.SlotB); err == nil {
		t.Fatal("expected switch to refuse while an update is pending")
	}
	if len(f.swapped) != 0 {
		t.Fatalf("must not swap when pending, got %v", f.swapped)
	}
}

func TestSwitchRefusesSameSlot(t *testing.T) {
	f := &fakeConn{cur: connector.SlotA}
	e := testEngine(t, f)
	if err := e.Switch(connector.SlotA); err == nil {
		t.Fatal("expected refusal switching to the current slot")
	}
}

// --- artifact builder ---

func sha256hex(data []byte) string {
	h := sha256.Sum256(data)
	return hex.EncodeToString(h[:])
}

func buildArtifact(t *testing.T, mutate func(*artifact.Manifest)) ([]byte, []byte) {
	t.Helper()
	image := bytes.Repeat([]byte("rootfs-bytes "), 1000)

	var comp bytes.Buffer
	zw, _ := zstd.NewWriter(&comp)
	zw.Write(image)
	zw.Close()

	m := artifact.Manifest{
		FormatVersion:     1,
		ArtifactName:      "wendyos-image-test-1.2.3",
		ArtifactVersion:   "1.2.3",
		CompatibleDevices: []string{"jetson-agx-thor"},
		Payload: artifact.Payload{
			Name:             "wendyos-image.ext4.zst",
			Size:             int64(len(image)),
			SHA256:           sha256hex(image),
			CompressedSHA256: sha256hex(comp.Bytes()),
			Compression:      "zstd",
		},
		MinToolVersion: "0.1.0",
	}
	if mutate != nil {
		mutate(&m)
	}

	manifestJSON, _ := json.Marshal(m)
	var buf bytes.Buffer
	tw := tar.NewWriter(&buf)
	for _, member := range []struct {
		name string
		data []byte
	}{
		{"manifest.json", manifestJSON},
		{m.Payload.Name, comp.Bytes()},
	} {
		tw.WriteHeader(&tar.Header{Name: member.name, Mode: 0o644, Size: int64(len(member.data))})
		tw.Write(member.data)
	}
	tw.Close()
	return buf.Bytes(), image
}

// --- engine under test ---

func testEngine(t *testing.T, f *fakeConn) *Engine {
	t.Helper()
	dir := t.TempDir()

	devicePath := filepath.Join(dir, "device-type")
	os.WriteFile(devicePath, []byte("BOARD=jetson-agx-thor\nMACHINE=jetson-agx-thor-devkit-nvme-wendyos\n"), 0o644)

	f.dev = filepath.Join(dir, "fake-partition")
	os.WriteFile(f.dev, nil, 0o644)

	return &Engine{
		Conn:           f,
		StateDir:       filepath.Join(dir, "state"),
		DeviceTypePath: devicePath,
		ToolVersion:    "0.1.0-dev",
	}
}

func TestInstallHappyPath(t *testing.T) {
	f := &fakeConn{cur: connector.SlotA}
	e := testEngine(t, f)
	art, image := buildArtifact(t, nil)

	res, err := e.Install(bytes.NewReader(art))
	if err != nil {
		t.Fatal(err)
	}
	if res.TargetSlot != connector.SlotB {
		t.Fatalf("target slot %v, want B", res.TargetSlot)
	}

	// device content == decompressed image
	got, _ := os.ReadFile(f.dev)
	if !bytes.Equal(got, image) {
		t.Fatal("device content differs from image")
	}

	// connector lifecycle: prepare then swap, on slot B, as an install
	// swap (stagePlatformUpdate=true so the connector inspects the new rootfs)
	if len(f.prepared) != 1 || f.prepared[0] != connector.SlotB {
		t.Fatalf("PrepareTarget calls: %v", f.prepared)
	}
	if len(f.swapped) != 1 || f.swapped[0] != connector.SlotB || !f.swapStage[0] {
		t.Fatalf("SwapSlot calls: %v stage=%v", f.swapped, f.swapStage)
	}

	// state persisted as swapped
	st, err := e.LoadState()
	if err != nil || st == nil {
		t.Fatalf("state: %v, %v", st, err)
	}
	if st.Phase != PhaseSwapped || st.TargetSlot != 1 || st.ArtifactVersion != "1.2.3" {
		t.Fatalf("state: %+v", st)
	}
}

func TestInstallRejectsWrongDevice(t *testing.T) {
	f := &fakeConn{cur: connector.SlotA}
	e := testEngine(t, f)
	art, _ := buildArtifact(t, func(m *artifact.Manifest) {
		m.CompatibleDevices = []string{"rpi5"}
	})

	_, err := e.Install(bytes.NewReader(art))
	var rej *RejectError
	if !errors.As(err, &rej) {
		t.Fatalf("want RejectError, got %v", err)
	}
	// nothing written, no state, no connector calls
	if got, _ := os.ReadFile(f.dev); len(got) != 0 {
		t.Fatal("device was written despite rejection")
	}
	if st, _ := e.LoadState(); st != nil {
		t.Fatal("state persisted despite rejection")
	}
	if len(f.swapped) != 0 {
		t.Fatal("SwapSlot called despite rejection")
	}
}

func TestInstallRejectsToolVersionGate(t *testing.T) {
	f := &fakeConn{cur: connector.SlotA}
	e := testEngine(t, f)
	art, _ := buildArtifact(t, func(m *artifact.Manifest) {
		m.MinToolVersion = "9.0.0"
	})
	_, err := e.Install(bytes.NewReader(art))
	var rej *RejectError
	if !errors.As(err, &rej) {
		t.Fatalf("want RejectError, got %v", err)
	}
}

func TestInstallRejectsDigestMismatch(t *testing.T) {
	f := &fakeConn{cur: connector.SlotA}
	e := testEngine(t, f)
	art, _ := buildArtifact(t, func(m *artifact.Manifest) {
		m.Payload.SHA256 = sha256hex([]byte("tampered"))
	})

	_, err := e.Install(bytes.NewReader(art))
	var rej *RejectError
	if !errors.As(err, &rej) {
		t.Fatalf("want RejectError, got %v", err)
	}
	// write happened (streaming), but: no state, no swap
	if st, _ := e.LoadState(); st != nil {
		t.Fatal("state persisted despite digest mismatch")
	}
	if len(f.swapped) != 0 {
		t.Fatal("SwapSlot called despite digest mismatch")
	}
}

func TestInstallRefusesWhenInFlight(t *testing.T) {
	f := &fakeConn{cur: connector.SlotA}
	e := testEngine(t, f)
	if err := e.SaveState(&State{Schema: 1, Phase: PhaseSwapped, ArtifactName: "previous"}); err != nil {
		t.Fatal(err)
	}
	art, _ := buildArtifact(t, nil)
	_, err := e.Install(bytes.NewReader(art))
	if err == nil || len(f.swapped) != 0 {
		t.Fatalf("in-flight update not refused: %v", err)
	}
}

func TestInstallSwapFailureKeepsWrittenState(t *testing.T) {
	f := &fakeConn{cur: connector.SlotA, failSwap: true}
	e := testEngine(t, f)
	art, _ := buildArtifact(t, nil)

	if _, err := e.Install(bytes.NewReader(art)); err == nil {
		t.Fatal("expected swap failure")
	}
	st, _ := e.LoadState()
	if st == nil || st.Phase != PhaseWritten {
		t.Fatalf("state after swap failure: %+v", st)
	}
}

func TestMarkGoodClearsState(t *testing.T) {
	f := &fakeConn{cur: connector.SlotA}
	e := testEngine(t, f)
	e.SaveState(&State{Schema: 1, Phase: PhaseWritten})
	if err := e.MarkGood(); err != nil {
		t.Fatal(err)
	}
	if f.markGood != 1 {
		t.Fatal("connector MarkGood not called")
	}
	if st, _ := e.LoadState(); st != nil {
		t.Fatal("state not cleared")
	}
}

func TestStatus(t *testing.T) {
	f := &fakeConn{cur: connector.SlotB}
	e := testEngine(t, f)
	info, err := e.Status(false)
	if err != nil {
		t.Fatal(err)
	}
	if info.Connector != "fake" || info.CurrentSlot != "B" || info.Pending != nil {
		t.Fatalf("status: %+v", info)
	}
}

func TestVersionAtLeast(t *testing.T) {
	for _, tc := range []struct {
		have, min string
		want      bool
	}{
		{"0.1.0-dev", "0.1.0", true},
		{"0.1.0", "0.2.0", false},
		{"1.0.0", "0.9.9", true},
		{"0.1.0", "", true},
		{"0.1.0", "garbage", true}, // malformed gate must not brick updates
		{"garbage", "0.1.0", false},
	} {
		if got := versionAtLeast(tc.have, tc.min); got != tc.want {
			t.Fatalf("versionAtLeast(%q,%q)=%v want %v", tc.have, tc.min, got, tc.want)
		}
	}
}
