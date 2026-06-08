// Package blockdev streams an update payload onto a rootfs partition.
// It is board-agnostic: the connector resolves WHICH device, this
// package only writes and hashes.
package blockdev

import (
	"bufio"
	"compress/gzip"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"os"

	"github.com/klauspost/compress/zstd"
)

// copyBufSize balances syscall count against memory; 1 MiB keeps a
// 25 GiB slot write at ~25k writes.
const copyBufSize = 1 << 20

// Progress receives the running count of UNCOMPRESSED bytes written.
// May be nil. Called at buffer granularity — cheap, but not per-byte.
type Progress func(written int64)

// WriteImage decompresses src (per compression: "zstd", "gzip", "none")
// and streams it to the block device at dst, computing a rolling sha256
// of the decompressed bytes. The device is fsynced before returning.
//
// dst is opened WITHOUT O_CREATE: if the partition node does not exist
// the write must fail rather than create a regular file where a device
// was expected.
//
// Returns the byte count and hex digest of what was actually written;
// the caller compares the digest against the artifact manifest BEFORE
// any slot swap.
func WriteImage(dst string, src io.Reader, compression string, progress Progress) (int64, string, error) {
	plain, closer, err := Decompressor(src, compression)
	if err != nil {
		return 0, "", err
	}
	if closer != nil {
		defer closer()
	}

	f, err := os.OpenFile(dst, os.O_WRONLY, 0)
	if err != nil {
		return 0, "", fmt.Errorf("open target %s: %w", dst, err)
	}
	defer f.Close()

	h := sha256.New()
	bw := bufio.NewWriterSize(f, copyBufSize)

	var written int64
	out := io.MultiWriter(bw, h)
	buf := make([]byte, copyBufSize)
	for {
		n, rerr := plain.Read(buf)
		if n > 0 {
			if _, werr := out.Write(buf[:n]); werr != nil {
				return written, "", fmt.Errorf("write %s: %w", dst, werr)
			}
			written += int64(n)
			if progress != nil {
				progress(written)
			}
		}
		if rerr == io.EOF {
			break
		}
		if rerr != nil {
			return written, "", fmt.Errorf("read payload: %w", rerr)
		}
	}

	if err := bw.Flush(); err != nil {
		return written, "", fmt.Errorf("flush %s: %w", dst, err)
	}
	if err := f.Sync(); err != nil {
		return written, "", fmt.Errorf("sync %s: %w", dst, err)
	}
	return written, hex.EncodeToString(h.Sum(nil)), nil
}

// Decompressor wraps src according to the manifest's compression field.
func Decompressor(src io.Reader, compression string) (io.Reader, func(), error) {
	switch compression {
	case "zstd":
		zr, err := zstd.NewReader(src)
		if err != nil {
			return nil, nil, fmt.Errorf("zstd: %w", err)
		}
		return zr.IOReadCloser(), func() { zr.Close() }, nil
	case "gzip":
		gr, err := gzip.NewReader(src)
		if err != nil {
			return nil, nil, fmt.Errorf("gzip: %w", err)
		}
		return gr, func() { gr.Close() }, nil
	case "none":
		return src, nil, nil
	default:
		return nil, nil, fmt.Errorf("unsupported compression %q", compression)
	}
}
