package tegrauefi

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/wendylabsinc/wendy-os-update/internal/connector"
)

func TestBootIsCompromised(t *testing.T) {
	c := testController(t)

	// no variables at all: not compromised
	if got, err := c.BootIsCompromised(); err != nil || got {
		t.Fatalf("no vars: got=%v err=%v", got, err)
	}

	// both normal
	writeSlotVar(t, c, connector.SlotA, []byte{0x07, 0, 0, 0, 0, 0, 0, 0})
	writeSlotVar(t, c, connector.SlotB, []byte{0x07, 0, 0, 0, 0, 0, 0, 0})
	if got, _ := c.BootIsCompromised(); got {
		t.Fatal("both normal: must not be compromised")
	}

	// slot B unbootable
	writeSlotVar(t, c, connector.SlotB, []byte{0x07, 0, 0, 0, 0xFF, 0, 0, 0})
	if got, _ := c.BootIsCompromised(); !got {
		t.Fatal("slot B 0xFF: must be compromised")
	}
}

// verifySetup prepares RootDir with the marker, optional saved version,
// and optional ESRT status.
func verifySetup(t *testing.T, c *Controller, savedVersion, esrtStatus string) {
	t.Helper()
	marker := c.RootDir + MarkerPath
	os.MkdirAll(filepath.Dir(marker), 0o755)
	os.WriteFile(marker, nil, 0o644)

	if savedVersion != "" {
		p := c.blVersionBeforePath()
		os.MkdirAll(filepath.Dir(p), 0o755)
		os.WriteFile(p, []byte(savedVersion+"\n"), 0o644)
	}
	if esrtStatus != "" {
		p := c.RootDir + ESRTStatusPath
		os.MkdirAll(filepath.Dir(p), 0o755)
		os.WriteFile(p, []byte(esrtStatus+"\n"), 0o644)
	}
}

func dumpSlotsInfoFake(t *testing.T, version string) string {
	return fakeNvbootctrl(t, "Current version: "+version+"\nCapsule update status: 1\n")
}

func TestVerifyPlatformUpdateNoMarker(t *testing.T) {
	c := testController(t)
	if err := c.VerifyPlatformUpdate(false); err != nil {
		t.Fatal(err)
	}
}

func TestVerifyPlatformUpdateVersionChanged(t *testing.T) {
	c := testController(t)
	c.Nvbootctrl = dumpSlotsInfoFake(t, "38.5.0")
	verifySetup(t, c, "38.4.0", "")

	if err := c.VerifyPlatformUpdate(true); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(c.blVersionBeforePath()); !os.IsNotExist(err) {
		t.Fatal("bl-version-before not cleaned up after success")
	}
}

func TestVerifyPlatformUpdateSameVersionESRTSuccess(t *testing.T) {
	c := testController(t)
	c.Nvbootctrl = dumpSlotsInfoFake(t, "38.4.0")
	verifySetup(t, c, "38.4.0", "0")

	if err := c.VerifyPlatformUpdate(true); err != nil {
		t.Fatal(err)
	}
}

func TestVerifyPlatformUpdateESRTCertFailure(t *testing.T) {
	c := testController(t)
	c.Nvbootctrl = dumpSlotsInfoFake(t, "38.4.0")
	verifySetup(t, c, "38.4.0", "6163")

	err := c.VerifyPlatformUpdate(true)
	if err == nil || !strings.Contains(err.Error(), "6163") {
		t.Fatalf("want 6163 cert error, got %v", err)
	}
}

func TestVerifyPlatformUpdateESRTStandardError(t *testing.T) {
	c := testController(t)
	c.Nvbootctrl = dumpSlotsInfoFake(t, "38.4.0")
	verifySetup(t, c, "38.4.0", "4")

	if err := c.VerifyPlatformUpdate(true); err == nil {
		t.Fatal("ESRT status 4 must fail verification")
	}
}

func TestVerifyPlatformUpdateFallbackBootSuccess(t *testing.T) {
	c := testController(t)
	c.Nvbootctrl = dumpSlotsInfoFake(t, "38.4.0")
	verifySetup(t, c, "", "") // no saved version, no ESRT

	if err := c.VerifyPlatformUpdate(true); err != nil {
		t.Fatalf("fallback must assume success: %v", err)
	}
}
