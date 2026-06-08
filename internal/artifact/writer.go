package artifact

// Pack creates .wendy artifacts (docs/manifest-schema.md). It lives in
// the same package as the reader so the format has exactly one
// implementation — the unit tests round-trip pack -> read forever.

import (
	"archive/tar"
	"compress/gzip"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"

	"github.com/klauspost/compress/zstd"
)

// PackOptions describes the artifact to build.
type PackOptions struct {
	ImagePath         string   // rootfs image (e.g. the deployed .ext4)
	ArtifactName      string   // e.g. wendyos-image-jetson-agx-thor-devkit-nvme-wendyos-0.16.0
	ArtifactVersion   string   // e.g. 0.16.0
	CompatibleDevices []string // WENDYOS_BOARD_ID values
	Compression       string   // "zstd" (default), "gzip", "none"
	BootloaderUpdate  bool     // informational (the rootfs marker decides)
	MinToolVersion    string   // optional forward-compat gate
}

// Pack streams ImagePath through the compressor into a temporary file
// (computing both digests in the same pass), then writes the tar in the
// frozen member order: manifest.json first, payload second.
func Pack(out io.Writer, opts PackOptions) (*Manifest, error) {
	if opts.Compression == "" {
		opts.Compression = "zstd"
	}

	imgFile, err := os.Open(opts.ImagePath)
	if err != nil {
		return nil, err
	}
	defer imgFile.Close()

	// Transparently expand an Android sparse image (.ext4.simg) to the
	// raw image; a raw input passes through unchanged. The payload we
	// store is always the raw image, so the device writes it verbatim.
	img, err := MaybeSparseReader(imgFile)
	if err != nil {
		return nil, fmt.Errorf("pack: %w", err)
	}

	tmp, err := os.CreateTemp("", "wendy-pack-*")
	if err != nil {
		return nil, err
	}
	defer func() {
		tmp.Close()
		os.Remove(tmp.Name())
	}()

	plainHash := sha256.New()
	compHash := sha256.New()
	compOut := io.MultiWriter(tmp, compHash)

	var (
		encoder io.Writer
		finish  func() error
	)
	switch opts.Compression {
	case "zstd":
		zw, err := zstd.NewWriter(compOut)
		if err != nil {
			return nil, fmt.Errorf("zstd: %w", err)
		}
		encoder, finish = zw, zw.Close
	case "gzip":
		gw := gzip.NewWriter(compOut)
		encoder, finish = gw, gw.Close
	case "none":
		encoder, finish = compOut, func() error { return nil }
	default:
		return nil, fmt.Errorf("unsupported compression %q", opts.Compression)
	}

	plainSize, err := io.Copy(io.MultiWriter(encoder, plainHash), img)
	if err != nil {
		return nil, fmt.Errorf("compress %s: %w", opts.ImagePath, err)
	}
	if err := finish(); err != nil {
		return nil, fmt.Errorf("compress %s: %w", opts.ImagePath, err)
	}
	compSize, err := tmp.Seek(0, io.SeekCurrent)
	if err != nil {
		return nil, err
	}

	m := &Manifest{
		FormatVersion:     1,
		ArtifactName:      opts.ArtifactName,
		ArtifactVersion:   opts.ArtifactVersion,
		CompatibleDevices: opts.CompatibleDevices,
		Payload: Payload{
			Name:             payloadName(opts.ImagePath, opts.Compression),
			Size:             plainSize,
			SHA256:           hex.EncodeToString(plainHash.Sum(nil)),
			CompressedSHA256: hex.EncodeToString(compHash.Sum(nil)),
			Compression:      opts.Compression,
		},
		BootloaderUpdate: opts.BootloaderUpdate,
		MinToolVersion:   opts.MinToolVersion,
	}
	if err := m.Validate(); err != nil {
		return nil, fmt.Errorf("pack: %w", err)
	}

	manifestJSON, err := json.MarshalIndent(m, "", "  ")
	if err != nil {
		return nil, err
	}

	tw := tar.NewWriter(out)
	if err := tw.WriteHeader(&tar.Header{Name: "manifest.json", Mode: 0o644, Size: int64(len(manifestJSON))}); err != nil {
		return nil, err
	}
	if _, err := tw.Write(manifestJSON); err != nil {
		return nil, err
	}
	if err := tw.WriteHeader(&tar.Header{Name: m.Payload.Name, Mode: 0o644, Size: compSize}); err != nil {
		return nil, err
	}
	if _, err := tmp.Seek(0, io.SeekStart); err != nil {
		return nil, err
	}
	if _, err := io.Copy(tw, tmp); err != nil {
		return nil, fmt.Errorf("write payload: %w", err)
	}
	if err := tw.Close(); err != nil {
		return nil, err
	}
	return m, nil
}

func payloadName(imagePath, compression string) string {
	base := filepath.Base(imagePath)
	// The stored payload is the RAW image even when the input was sparse;
	// drop the .simg suffix so the name reflects the actual content.
	base = strings.TrimSuffix(base, ".simg")
	switch compression {
	case "zstd":
		return base + ".zst"
	case "gzip":
		return base + ".gz"
	default:
		return base
	}
}
