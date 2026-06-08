package blockdev

import (
	"bytes"
	"compress/gzip"
	"crypto/sha256"
	"encoding/hex"
	"os"
	"path/filepath"
	"testing"

	"github.com/klauspost/compress/zstd"
)

func sha256hex(data []byte) string {
	h := sha256.Sum256(data)
	return hex.EncodeToString(h[:])
}

// target creates a pre-existing file standing in for the partition node
// (WriteImage must never create its target).
func target(t *testing.T) string {
	t.Helper()
	p := filepath.Join(t.TempDir(), "fake-partition")
	if err := os.WriteFile(p, nil, 0o644); err != nil {
		t.Fatal(err)
	}
	return p
}

func TestWriteImageZstd(t *testing.T) {
	image := bytes.Repeat([]byte("rootfs data "), 100000) // ~1.2 MB, crosses buffer boundary
	var comp bytes.Buffer
	zw, _ := zstd.NewWriter(&comp)
	zw.Write(image)
	zw.Close()

	dst := target(t)
	var lastProgress int64
	n, digest, err := WriteImage(dst, &comp, "zstd", func(w int64) { lastProgress = w })
	if err != nil {
		t.Fatal(err)
	}
	if n != int64(len(image)) || lastProgress != n {
		t.Fatalf("written=%d progress=%d want %d", n, lastProgress, len(image))
	}
	if digest != sha256hex(image) {
		t.Fatal("digest mismatch")
	}
	got, _ := os.ReadFile(dst)
	if !bytes.Equal(got, image) {
		t.Fatal("device content differs")
	}
}

func TestWriteImageGzip(t *testing.T) {
	image := []byte("small image")
	var comp bytes.Buffer
	gw := gzip.NewWriter(&comp)
	gw.Write(image)
	gw.Close()

	dst := target(t)
	n, digest, err := WriteImage(dst, &comp, "gzip", nil)
	if err != nil {
		t.Fatal(err)
	}
	if n != int64(len(image)) || digest != sha256hex(image) {
		t.Fatalf("n=%d digest=%s", n, digest)
	}
}

func TestWriteImageNone(t *testing.T) {
	image := []byte("uncompressed image")
	dst := target(t)
	n, digest, err := WriteImage(dst, bytes.NewReader(image), "none", nil)
	if err != nil {
		t.Fatal(err)
	}
	if n != int64(len(image)) || digest != sha256hex(image) {
		t.Fatalf("n=%d digest=%s", n, digest)
	}
}

func TestWriteImageUnknownCompression(t *testing.T) {
	if _, _, err := WriteImage(target(t), bytes.NewReader(nil), "xz", nil); err == nil {
		t.Fatal("expected unsupported-compression error")
	}
}

func TestWriteImageMissingTarget(t *testing.T) {
	missing := filepath.Join(t.TempDir(), "no-such-device")
	_, _, err := WriteImage(missing, bytes.NewReader([]byte("x")), "none", nil)
	if err == nil {
		t.Fatal("expected error: target must exist (never create a file where a device was expected)")
	}
	if _, statErr := os.Stat(missing); !os.IsNotExist(statErr) {
		t.Fatal("WriteImage created its target — must never happen")
	}
}

func TestWriteImageCorruptStream(t *testing.T) {
	dst := target(t)
	if _, _, err := WriteImage(dst, bytes.NewReader([]byte("not zstd at all")), "zstd", nil); err == nil {
		t.Fatal("expected decompression error")
	}
}
