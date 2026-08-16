package tegrauefi

import (
	"os"
	"path/filepath"
	"testing"
)

// copyFileSync stages the capsule via a temp file and a rename, so a failed
// write cannot destroy the capsule already staged on the ESP. Writing the
// destination directly with O_TRUNC did: a short write (ENOSPC on a full ESP)
// left a truncated stub where a good capsule had been.
func TestCopyFileSyncReplacesAtomically(t *testing.T) {
	dir := t.TempDir()
	src := filepath.Join(dir, "tegra-bl.cap")
	dst := filepath.Join(dir, "TEGRA_BL.Cap")

	if err := os.WriteFile(src, []byte("new capsule"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(dst, []byte("previously staged capsule"), 0o644); err != nil {
		t.Fatal(err)
	}

	if err := copyFileSync(src, dst); err != nil {
		t.Fatalf("copyFileSync: %v", err)
	}

	got, err := os.ReadFile(dst)
	if err != nil {
		t.Fatal(err)
	}
	if string(got) != "new capsule" {
		t.Errorf("dst = %q, want %q", got, "new capsule")
	}
	assertNoTempLeft(t, dir, dst)
}

// A failed copy must leave the previously staged capsule intact. The source is
// unreadable here, which stands in for any error before the rename — the
// realistic one being ENOSPC part-way through the write.
func TestCopyFileSyncFailureKeepsPreviousCapsule(t *testing.T) {
	dir := t.TempDir()
	dst := filepath.Join(dir, "TEGRA_BL.Cap")
	const previous = "previously staged capsule"

	if err := os.WriteFile(dst, []byte(previous), 0o644); err != nil {
		t.Fatal(err)
	}

	if err := copyFileSync(filepath.Join(dir, "does-not-exist.cap"), dst); err == nil {
		t.Fatal("copyFileSync succeeded on a missing source, want error")
	}

	got, err := os.ReadFile(dst)
	if err != nil {
		t.Fatalf("previously staged capsule was removed: %v", err)
	}
	if string(got) != previous {
		t.Errorf("dst = %q, want the previous capsule %q", got, previous)
	}
	assertNoTempLeft(t, dir, dst)
}

// A temp file left by an earlier interrupted staging must not block the next
// one, and must not survive it either.
func TestCopyFileSyncReclaimsStaleTemp(t *testing.T) {
	dir := t.TempDir()
	src := filepath.Join(dir, "tegra-bl.cap")
	dst := filepath.Join(dir, "TEGRA_BL.Cap")

	if err := os.WriteFile(src, []byte("new capsule"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(dst+".tmp", []byte("interrupted staging"), 0o644); err != nil {
		t.Fatal(err)
	}

	if err := copyFileSync(src, dst); err != nil {
		t.Fatalf("copyFileSync with a stale temp present: %v", err)
	}

	got, err := os.ReadFile(dst)
	if err != nil {
		t.Fatal(err)
	}
	if string(got) != "new capsule" {
		t.Errorf("dst = %q, want %q", got, "new capsule")
	}
	assertNoTempLeft(t, dir, dst)
}

// The ESP is small and never swept, so staging must not leave anything behind
// beyond the capsule itself.
func assertNoTempLeft(t *testing.T, dir, dst string) {
	t.Helper()
	if _, err := os.Stat(dst + ".tmp"); !os.IsNotExist(err) {
		t.Errorf("temp file %s still present after staging", dst+".tmp")
	}
	entries, err := os.ReadDir(dir)
	if err != nil {
		t.Fatal(err)
	}
	for _, e := range entries {
		if filepath.Ext(e.Name()) == ".tmp" {
			t.Errorf("unexpected leftover %s", e.Name())
		}
	}
}
