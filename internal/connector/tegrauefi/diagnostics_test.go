package tegrauefi

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/wendylabsinc/wendyos-update/internal/connector"
)

func kvValue(kv []connector.KV, key string) string {
	for _, e := range kv {
		if e.Key == key {
			return e.Value
		}
	}

	return ""
}

// SystemStatus reports the capsule outcome from nvbootctrl's unambiguous
// "Capsule update status" field when present (0=none, 1=success,
// 2=boot-failed, 3=install-failed), not the ESRT last_attempt_status (whose 0
// means both "success" and "no attempt").
func TestSystemStatusCapsuleStatusFromNvbootctrl(t *testing.T) {
	for _, tc := range []struct {
		name string
		out  string
		want string
	}{
		{"success", "Current version: 39.2.0\nCapsule update status: 1\n", "1 (success)"},
		{"none", "Current version: 39.2.0\nCapsule update status: 0\n", "0 (none)"},
		{"install failed", "Current version: 39.2.0\nCapsule update status: 3\n", "3 (install failed)"},
		// Defensive: even if dump-slots-info repeated the version line, only one
		// "bootloader version" must be emitted (guarded below).
		{"duplicate version lines", "Current version: 39.2.0\nCurrent version: 39.2.0\nCapsule update status: 1\n", "1 (success)"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			c := testController(t)
			c.Nvbootctrl = fakeNvbootctrl(t, tc.out)
			kv := c.SystemStatus()
			if got := kvValue(kv, "capsule update status"); got != tc.want {
				t.Fatalf("capsule update status = %q, want %q", got, tc.want)
			}
			if got := kvValue(kv, "bootloader version"); got != "39.2.0" {
				t.Fatalf("bootloader version = %q, want 39.2.0", got)
			}
			nVer := 0
			for _, e := range kv {
				if e.Key == "bootloader version" {
					nVer++
				}
			}
			if nVer != 1 {
				t.Fatalf("expected exactly 1 bootloader version line, got %d: %+v", nVer, kv)
			}
			// The ambiguous ESRT line must not appear when nvbootctrl reports.
			if v := kvValue(kv, "last capsule status"); v != "" {
				t.Fatalf("unexpected ESRT 'last capsule status' = %q when nvbootctrl reports", v)
			}
		})
	}
}

// When nvbootctrl omits the capsule field (older L4T), SystemStatus falls back
// to ESRT and disambiguates last_attempt_status 0 with last_attempt_version, so
// "no attempt" is no longer mislabeled "success".
func TestSystemStatusESRTFallbackDisambiguatesZero(t *testing.T) {
	writeESRT := func(t *testing.T, c *Controller, status, version string) {
		t.Helper()
		dir := filepath.Dir(c.RootDir + ESRTStatusPath)
		if err := os.MkdirAll(dir, 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(dir, "last_attempt_status"), []byte(status), 0o644); err != nil {
			t.Fatal(err)
		}
		if version != "" {
			if err := os.WriteFile(filepath.Join(dir, "last_attempt_version"), []byte(version), 0o644); err != nil {
				t.Fatal(err)
			}
		}
	}

	for _, tc := range []struct {
		name    string
		status  string
		version string
		want    string
	}{
		{"no attempt", "0", "0", "0 (no update attempted)"},
		{"real success", "0", "2556416", "0 (success)"},
		{"nonzero passthrough", "9", "2556416", "9"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			c := testController(t)
			// nvbootctrl WITHOUT a capsule line forces the ESRT fallback.
			c.Nvbootctrl = fakeNvbootctrl(t, "Current version: 39.2.0\n")
			writeESRT(t, c, tc.status, tc.version)
			kv := c.SystemStatus()
			if got := kvValue(kv, "last capsule status"); got != tc.want {
				t.Fatalf("last capsule status = %q, want %q", got, tc.want)
			}
			if v := kvValue(kv, "capsule update status"); v != "" {
				t.Fatalf("unexpected nvbootctrl 'capsule update status' = %q in fallback", v)
			}
		})
	}
}
