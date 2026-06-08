package artifact

import (
	"archive/tar"
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"io"
	"testing"

	"github.com/klauspost/compress/zstd"
)

// buildArtifact assembles an in-memory .wendy tar. memberOrder allows
// malformed layouts for negative tests.
func buildArtifact(t *testing.T, m Manifest, payload []byte, memberOrder []string) []byte {
	t.Helper()
	manifestJSON, err := json.Marshal(m)
	if err != nil {
		t.Fatal(err)
	}
	members := map[string][]byte{
		"manifest.json":  manifestJSON,
		m.Payload.Name:   payload,
		"manifest.sig":   []byte("reserved"),
		"unexpected.bin": []byte("nope"),
	}
	var buf bytes.Buffer
	tw := tar.NewWriter(&buf)
	for _, name := range memberOrder {
		data := members[name]
		if err := tw.WriteHeader(&tar.Header{Name: name, Mode: 0o644, Size: int64(len(data))}); err != nil {
			t.Fatal(err)
		}
		if _, err := tw.Write(data); err != nil {
			t.Fatal(err)
		}
	}
	if err := tw.Close(); err != nil {
		t.Fatal(err)
	}
	return buf.Bytes()
}

func zstdCompress(t *testing.T, data []byte) []byte {
	t.Helper()
	var buf bytes.Buffer
	zw, err := zstd.NewWriter(&buf)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := zw.Write(data); err != nil {
		t.Fatal(err)
	}
	if err := zw.Close(); err != nil {
		t.Fatal(err)
	}
	return buf.Bytes()
}

func sha256hex(data []byte) string {
	h := sha256.Sum256(data)
	return hex.EncodeToString(h[:])
}

func validManifest(image, compressed []byte) Manifest {
	return Manifest{
		FormatVersion:     1,
		ArtifactName:      "wendyos-image-test-0.1.0",
		ArtifactVersion:   "0.1.0",
		CompatibleDevices: []string{"jetson-agx-thor"},
		Payload: Payload{
			Name:             "wendyos-image.ext4.zst",
			Size:             int64(len(image)),
			SHA256:           sha256hex(image),
			CompressedSHA256: sha256hex(compressed),
			Compression:      "zstd",
		},
		MinToolVersion: "0.1.0",
	}
}

func TestOpenAndPayloadHappyPath(t *testing.T) {
	image := bytes.Repeat([]byte("wendy rootfs block "), 4096)
	compressed := zstdCompress(t, image)
	m := validManifest(image, compressed)
	art := buildArtifact(t, m, compressed, []string{"manifest.json", m.Payload.Name})

	r, err := Open(bytes.NewReader(art))
	if err != nil {
		t.Fatal(err)
	}
	if r.Manifest.ArtifactName != m.ArtifactName {
		t.Fatalf("manifest roundtrip: %+v", r.Manifest)
	}

	p, err := r.Payload()
	if err != nil {
		t.Fatal(err)
	}
	got, err := io.ReadAll(p)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(got, compressed) {
		t.Fatal("payload bytes differ")
	}
	// digest check: decompressed digest comes from the (test-local) image
	if err := r.VerifyPayloadDigests(sha256hex(image)); err != nil {
		t.Fatal(err)
	}
}

func TestOpenSkipsManifestSig(t *testing.T) {
	image := []byte("img")
	compressed := zstdCompress(t, image)
	m := validManifest(image, compressed)
	art := buildArtifact(t, m, compressed, []string{"manifest.json", "manifest.sig", m.Payload.Name})

	r, err := Open(bytes.NewReader(art))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := r.Payload(); err != nil {
		t.Fatalf("manifest.sig should be skipped: %v", err)
	}
}

func TestOpenRejectsManifestNotFirst(t *testing.T) {
	image := []byte("img")
	compressed := zstdCompress(t, image)
	m := validManifest(image, compressed)
	art := buildArtifact(t, m, compressed, []string{m.Payload.Name, "manifest.json"})

	if _, err := Open(bytes.NewReader(art)); err == nil {
		t.Fatal("expected error: manifest not first")
	}
}

func TestPayloadRejectsUnexpectedMember(t *testing.T) {
	image := []byte("img")
	compressed := zstdCompress(t, image)
	m := validManifest(image, compressed)
	art := buildArtifact(t, m, compressed, []string{"manifest.json", "unexpected.bin", m.Payload.Name})

	r, err := Open(bytes.NewReader(art))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := r.Payload(); err == nil {
		t.Fatal("expected error: unexpected member before payload")
	}
}

func TestPayloadMissing(t *testing.T) {
	image := []byte("img")
	compressed := zstdCompress(t, image)
	m := validManifest(image, compressed)
	art := buildArtifact(t, m, compressed, []string{"manifest.json"})

	r, err := Open(bytes.NewReader(art))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := r.Payload(); err == nil {
		t.Fatal("expected error: payload member missing")
	}
}

func TestVerifyDigestMismatch(t *testing.T) {
	image := []byte("img")
	compressed := zstdCompress(t, image)
	m := validManifest(image, compressed)
	art := buildArtifact(t, m, compressed, []string{"manifest.json", m.Payload.Name})

	r, _ := Open(bytes.NewReader(art))
	p, _ := r.Payload()
	if _, err := io.ReadAll(p); err != nil {
		t.Fatal(err)
	}
	if err := r.VerifyPayloadDigests(sha256hex([]byte("tampered"))); err == nil {
		t.Fatal("expected uncompressed digest mismatch")
	}
}

func TestManifestValidate(t *testing.T) {
	image := []byte("img")
	compressed := zstdCompress(t, image)

	bad := validManifest(image, compressed)
	bad.FormatVersion = 2
	if err := bad.Validate(); err == nil {
		t.Fatal("format_version 2 must be rejected")
	}

	bad = validManifest(image, compressed)
	bad.CompatibleDevices = nil
	if err := bad.Validate(); err == nil {
		t.Fatal("empty compatible_devices must be rejected")
	}

	bad = validManifest(image, compressed)
	bad.Payload.Compression = "xz"
	if err := bad.Validate(); err == nil {
		t.Fatal("unsupported compression must be rejected")
	}

	good := validManifest(image, compressed)
	if err := good.Validate(); err != nil {
		t.Fatal(err)
	}
	if !good.CompatibleWith("jetson-agx-thor") || good.CompatibleWith("rpi5") {
		t.Fatal("CompatibleWith wrong")
	}
}
