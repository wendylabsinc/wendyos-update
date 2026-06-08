package artifact

import (
	"bytes"
	"encoding/binary"
	"io"
	"testing"
)

// buildSparse encodes raw into a minimal Android sparse image using all
// chunk types: a RAW chunk, a DONTCARE (zero) chunk, and a FILL chunk.
// raw must be laid out as [rawBlk | zeroBlk | fillBlk], each blkSz.
func buildSparse(t *testing.T, blkSz uint32, rawBlk, fillPattern []byte) ([]byte, []byte) {
	t.Helper()
	if len(rawBlk) != int(blkSz) || len(fillPattern) != 4 {
		t.Fatal("test setup: bad block/pattern sizes")
	}
	zeroBlk := make([]byte, blkSz)
	fillBlk := make([]byte, blkSz)
	for i := range fillBlk {
		fillBlk[i] = fillPattern[i&3]
	}
	rawImage := append(append(append([]byte{}, rawBlk...), zeroBlk...), fillBlk...)

	var b bytes.Buffer
	w := func(v any) { binary.Write(&b, binary.LittleEndian, v) }
	// file header (28 bytes)
	w(uint32(sparseMagic))
	w(uint16(1)) // major
	w(uint16(0)) // minor
	w(uint16(28))
	w(uint16(12))
	w(blkSz)
	w(uint32(3)) // total_blks
	w(uint32(3)) // total_chunks
	w(uint32(0)) // checksum (ignored)

	// RAW chunk
	w(uint16(chunkRaw))
	w(uint16(0))
	w(uint32(1))            // blks
	w(uint32(12 + blkSz))   // total_sz
	b.Write(rawBlk)

	// DONTCARE chunk
	w(uint16(chunkDontCare))
	w(uint16(0))
	w(uint32(1)) // blks
	w(uint32(12)) // total_sz (no payload)

	// FILL chunk
	w(uint16(chunkFill))
	w(uint16(0))
	w(uint32(1))      // blks
	w(uint32(12 + 4)) // total_sz
	b.Write(fillPattern)

	return b.Bytes(), rawImage
}

func TestSparseExpand(t *testing.T) {
	blkSz := uint32(4096)
	rawBlk := bytes.Repeat([]byte{0xAB}, int(blkSz))
	pattern := []byte{0xDE, 0xAD, 0xBE, 0xEF}

	sparse, wantRaw := buildSparse(t, blkSz, rawBlk, pattern)

	r, err := MaybeSparseReader(bytes.NewReader(sparse))
	if err != nil {
		t.Fatal(err)
	}
	got, err := io.ReadAll(r)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(got, wantRaw) {
		t.Fatalf("expanded image mismatch: got %d bytes, want %d", len(got), len(wantRaw))
	}
}

func TestSparseExpandSmallBuffer(t *testing.T) {
	// Reading 1 byte at a time must produce the identical stream — guards
	// the chunk-boundary handling in Read.
	blkSz := uint32(4096)
	rawBlk := bytes.Repeat([]byte{0x5A}, int(blkSz))
	pattern := []byte{0x01, 0x02, 0x03, 0x04}
	sparse, wantRaw := buildSparse(t, blkSz, rawBlk, pattern)

	r, err := MaybeSparseReader(bytes.NewReader(sparse))
	if err != nil {
		t.Fatal(err)
	}
	var got []byte
	buf := make([]byte, 1)
	for {
		n, err := r.Read(buf)
		got = append(got, buf[:n]...)
		if err == io.EOF {
			break
		}
		if err != nil {
			t.Fatal(err)
		}
	}
	if !bytes.Equal(got, wantRaw) {
		t.Fatal("byte-at-a-time expansion mismatch")
	}
}

func TestNonSparsePassThrough(t *testing.T) {
	raw := []byte("not a sparse image, just raw ext4 bytes...")
	r, err := MaybeSparseReader(bytes.NewReader(raw))
	if err != nil {
		t.Fatal(err)
	}
	got, err := io.ReadAll(r)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(got, raw) {
		t.Fatal("raw input must pass through unchanged")
	}
}

func TestShortInputPassThrough(t *testing.T) {
	raw := []byte{1, 2} // shorter than the 4-byte magic
	r, err := MaybeSparseReader(bytes.NewReader(raw))
	if err != nil {
		t.Fatal(err)
	}
	got, _ := io.ReadAll(r)
	if !bytes.Equal(got, raw) {
		t.Fatal("short input must pass through")
	}
}
