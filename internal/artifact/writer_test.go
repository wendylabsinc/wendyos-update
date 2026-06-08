package artifact

import (
	"bytes"
	"compress/gzip"
	"io"
	"os"
	"path/filepath"
	"testing"

	"github.com/klauspost/compress/zstd"
)

func packToBytes(t *testing.T, image []byte, compression string) ([]byte, *Manifest) {
	t.Helper()
	imgPath := filepath.Join(t.TempDir(), "wendyos-image.ext4")
	if err := os.WriteFile(imgPath, image, 0o644); err != nil {
		t.Fatal(err)
	}
	var out bytes.Buffer
	m, err := Pack(&out, PackOptions{
		ImagePath:         imgPath,
		ArtifactName:      "wendyos-image-test-9.9.9",
		ArtifactVersion:   "9.9.9",
		CompatibleDevices: []string{"jetson-agx-thor"},
		Compression:       compression,
		MinToolVersion:    "0.1.0",
	})
	if err != nil {
		t.Fatal(err)
	}
	return out.Bytes(), m
}

// TestPackReadRoundTrip is the guarantee that packer and reader can
// never drift: every byte must survive pack -> Open -> Payload ->
// decompress, and both digests must check out.
func TestPackReadRoundTrip(t *testing.T) {
	for _, compression := range []string{"zstd", "gzip", "none"} {
		image := bytes.Repeat([]byte("round trip "+compression+" "), 50000)
		art, m := packToBytes(t, image, compression)

		r, err := Open(bytes.NewReader(art))
		if err != nil {
			t.Fatalf("%s: %v", compression, err)
		}
		if r.Manifest.ArtifactName != m.ArtifactName || r.Manifest.Payload.Size != int64(len(image)) {
			t.Fatalf("%s: manifest roundtrip: %+v", compression, r.Manifest)
		}

		p, err := r.Payload()
		if err != nil {
			t.Fatalf("%s: %v", compression, err)
		}
		var plain io.Reader = p
		switch compression {
		case "zstd":
			zr, err := zstd.NewReader(p)
			if err != nil {
				t.Fatal(err)
			}
			defer zr.Close()
			plain = zr.IOReadCloser()
		case "gzip":
			gr, err := gzip.NewReader(p)
			if err != nil {
				t.Fatal(err)
			}
			defer gr.Close()
			plain = gr
		}
		got, err := io.ReadAll(plain)
		if err != nil {
			t.Fatalf("%s: %v", compression, err)
		}
		if !bytes.Equal(got, image) {
			t.Fatalf("%s: image bytes corrupted in round trip", compression)
		}
		if err := r.VerifyPayloadDigests(sha256hex(image)); err != nil {
			t.Fatalf("%s: %v", compression, err)
		}
	}
}

func TestPackRejectsBadOptions(t *testing.T) {
	imgPath := filepath.Join(t.TempDir(), "img")
	os.WriteFile(imgPath, []byte("x"), 0o644)

	var out bytes.Buffer
	// no devices
	if _, err := Pack(&out, PackOptions{
		ImagePath: imgPath, ArtifactName: "a", ArtifactVersion: "1",
	}); err == nil {
		t.Fatal("empty compatible_devices must be rejected")
	}
	// bad compression
	if _, err := Pack(&out, PackOptions{
		ImagePath: imgPath, ArtifactName: "a", ArtifactVersion: "1",
		CompatibleDevices: []string{"d"}, Compression: "xz",
	}); err == nil {
		t.Fatal("unsupported compression must be rejected")
	}
	// missing image
	if _, err := Pack(&out, PackOptions{
		ImagePath: filepath.Join(t.TempDir(), "absent"), ArtifactName: "a",
		ArtifactVersion: "1", CompatibleDevices: []string{"d"},
	}); err == nil {
		t.Fatal("missing image must be rejected")
	}
}
