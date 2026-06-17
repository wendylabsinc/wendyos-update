package main

// `wendyos-update pack` — build a .wendy artifact from a rootfs image.
// Host-side verb (build machines / CI / the future image bbclass via a
// -native recipe); it does not touch device state.

import (
	"crypto/sha256"
	"encoding/hex"
	"flag"
	"fmt"
	"io"
	"os"
	"strings"

	"github.com/wendylabsinc/wendyos-update/internal/artifact"
	"github.com/wendylabsinc/wendyos-update/internal/blockdev"
)

type stringList []string

func (s *stringList) String() string     { return strings.Join(*s, ",") }
func (s *stringList) Set(v string) error { *s = append(*s, v); return nil }

func cmdPack(args []string) error {
	fs := flag.NewFlagSet("pack", flag.ContinueOnError)
	var (
		image       = fs.String("image", "", "rootfs image to package (e.g. the deployed .ext4)")
		name        = fs.String("name", "", "artifact name (e.g. wendyos-image-<machine>-<version>)")
		version     = fs.String("version", "", "artifact version (e.g. 0.16.0)")
		compression = fs.String("compression", "zstd", "payload compression: zstd|gzip|none")
		blUpdate    = fs.Bool("bootloader-update", false, "informational flag (the rootfs marker decides at install time)")
		minTool     = fs.String("min-tool-version", "", "minimum wendyos-update version able to install this artifact")
		output      = fs.String("o", "", "output .wendy path")
		noVerify    = fs.Bool("no-verify", false, "skip the read-back verification pass")
		devices     stringList
	)
	fs.Var(&devices, "device", "compatible device type (WENDYOS_BOARD_ID); repeatable")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *image == "" || *name == "" || *version == "" || *output == "" || len(devices) == 0 {
		fs.Usage()
		return fmt.Errorf("pack: --image, --name, --version, --device, and -o are required")
	}

	out, err := os.OpenFile(*output, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o644)
	if err != nil {
		return err
	}
	m, err := artifact.Pack(out, artifact.PackOptions{
		ImagePath:         *image,
		ArtifactName:      *name,
		ArtifactVersion:   *version,
		CompatibleDevices: devices,
		Compression:       *compression,
		BootloaderUpdate:  *blUpdate,
		MinToolVersion:    *minTool,
	})
	if err != nil {
		out.Close()
		os.Remove(*output)
		return fmt.Errorf("pack: %w", err)
	}
	if err := out.Close(); err != nil {
		return fmt.Errorf("pack: %w", err)
	}

	if !*noVerify {
		if err := verifyPacked(*output); err != nil {
			os.Remove(*output)
			return fmt.Errorf("pack: self-verification failed (artifact removed): %w", err)
		}
	}

	fmt.Fprintf(os.Stderr, "wendyos-update: packed %s (%s, payload %d bytes, %s)\n",
		*output, m.ArtifactName, m.Payload.Size, m.Payload.Compression)
	return nil
}

// verifyPacked re-reads the artifact exactly as a device would:
// manifest-first parse, payload streamed through the decompressor with
// rolling digests checked against the manifest.
func verifyPacked(path string) error {
	f, err := os.Open(path)
	if err != nil {
		return err
	}
	defer f.Close()

	r, err := artifact.Open(f)
	if err != nil {
		return err
	}
	p, err := r.Payload()
	if err != nil {
		return err
	}
	plain, closer, err := blockdev.Decompressor(p, r.Manifest.Payload.Compression)
	if err != nil {
		return err
	}
	if closer != nil {
		defer closer()
	}
	h := sha256.New()
	n, err := io.Copy(h, plain)
	if err != nil {
		return err
	}
	if n != r.Manifest.Payload.Size {
		return fmt.Errorf("payload size %d, manifest says %d", n, r.Manifest.Payload.Size)
	}
	return r.VerifyPayloadDigests(hex.EncodeToString(h.Sum(nil)))
}
