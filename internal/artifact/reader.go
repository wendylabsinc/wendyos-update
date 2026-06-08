package artifact

import (
	"archive/tar"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"hash"
	"io"
	"path"
	"strings"
)

// maxManifestSize bounds manifest.json so a malformed artifact cannot
// exhaust memory (the manifest is a few hundred bytes in practice).
const maxManifestSize = 4 << 20

// Reader streams a .wendy artifact (docs/manifest-schema.md):
// a tar with manifest.json FIRST, then the payload — one pass, no
// temp copy. Construct with Open, then call Payload exactly once,
// consume it fully, and finish with VerifyPayloadDigests.
type Reader struct {
	Manifest Manifest

	tr           *tar.Reader
	compHash     hash.Hash
	payloadTaken bool
}

// Open reads and validates the manifest (the first tar member).
func Open(r io.Reader) (*Reader, error) {
	tr := tar.NewReader(r)

	hdr, err := tr.Next()
	if err != nil {
		return nil, fmt.Errorf("artifact: not a tar stream or empty: %w", err)
	}
	if memberName(hdr) != "manifest.json" {
		return nil, fmt.Errorf("artifact: first member must be manifest.json, got %q", hdr.Name)
	}
	if hdr.Size > maxManifestSize {
		return nil, fmt.Errorf("artifact: manifest.json too large (%d bytes)", hdr.Size)
	}

	var m Manifest
	dec := json.NewDecoder(io.LimitReader(tr, maxManifestSize))
	if err := dec.Decode(&m); err != nil {
		return nil, fmt.Errorf("artifact: parse manifest.json: %w", err)
	}
	if err := m.Validate(); err != nil {
		return nil, fmt.Errorf("artifact: invalid manifest: %w", err)
	}

	return &Reader{Manifest: m, tr: tr}, nil
}

// Payload advances to the payload member and returns a reader over its
// (still compressed) bytes. The reader is teed into a sha256 so the
// stored-bytes digest can be verified after consumption. manifest.sig
// members are skipped (reserved, unverified in v1).
func (r *Reader) Payload() (io.Reader, error) {
	if r.payloadTaken {
		return nil, fmt.Errorf("artifact: Payload may only be called once")
	}
	for {
		hdr, err := r.tr.Next()
		if err == io.EOF {
			return nil, fmt.Errorf("artifact: payload member %q not found", r.Manifest.Payload.Name)
		}
		if err != nil {
			return nil, fmt.Errorf("artifact: reading tar: %w", err)
		}
		name := memberName(hdr)
		if name == "manifest.sig" {
			continue // reserved for future signing; ignored in v1
		}
		if name != r.Manifest.Payload.Name {
			return nil, fmt.Errorf("artifact: unexpected member %q before payload %q", hdr.Name, r.Manifest.Payload.Name)
		}
		r.payloadTaken = true
		r.compHash = sha256.New()
		return io.TeeReader(r.tr, r.compHash), nil
	}
}

// VerifyPayloadDigests is called after the payload has been fully
// consumed. uncompressedSHA256 is the rolling digest the writer computed
// over the DECOMPRESSED stream; the compressed-bytes digest was
// accumulated by the tee in Payload. Both must match the manifest.
func (r *Reader) VerifyPayloadDigests(uncompressedSHA256 string) error {
	if !r.payloadTaken {
		return fmt.Errorf("artifact: payload was never read")
	}
	if !strings.EqualFold(uncompressedSHA256, r.Manifest.Payload.SHA256) {
		return fmt.Errorf("artifact: payload sha256 mismatch: got %s, manifest %s",
			uncompressedSHA256, r.Manifest.Payload.SHA256)
	}
	if want := r.Manifest.Payload.CompressedSHA256; want != "" {
		got := hex.EncodeToString(r.compHash.Sum(nil))
		if !strings.EqualFold(got, want) {
			return fmt.Errorf("artifact: compressed payload sha256 mismatch: got %s, manifest %s", got, want)
		}
	}
	return nil
}

// memberName normalizes tar member names ("./manifest.json" ==
// "manifest.json").
func memberName(hdr *tar.Header) string {
	return strings.TrimPrefix(path.Clean(hdr.Name), "./")
}
