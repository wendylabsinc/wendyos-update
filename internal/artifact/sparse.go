package artifact

// Streaming reader for the Android sparse image format (the .ext4.simg
// that Tegra/AOSP flashing tools produce). It expands to the raw image
// on the fly so the packer can treat a sparse input exactly like a raw
// one — no external simg2img, works on host, CI, and device alike.
//
// Format (little-endian), per AOSP system/core/libsparse/sparse_format.h:
//
//   file header (28 bytes):
//     magic            uint32  0xed26ff3a
//     major, minor     uint16  (1, 0)
//     file_hdr_sz      uint16  (28)
//     chunk_hdr_sz     uint16  (12)
//     blk_sz           uint32  (multiple of 4, e.g. 4096)
//     total_blks       uint32  blocks in the output image
//     total_chunks     uint32
//     image_checksum   uint32  (crc32; not verified here — the artifact
//                               carries its own sha256)
//   then total_chunks chunks, each a 12-byte header:
//     chunk_type       uint16  RAW 0xCAC1 | FILL 0xCAC2 | DONTCARE 0xCAC3 | CRC32 0xCAC4
//     reserved         uint16
//     chunk_blks       uint32  output blocks this chunk expands to
//     total_sz         uint32  chunk header + payload on disk
//   payloads:
//     RAW      -> chunk_blks*blk_sz raw bytes
//     FILL     -> 4-byte pattern, repeated to fill chunk_blks*blk_sz
//     DONTCARE -> no payload; emit chunk_blks*blk_sz zero bytes
//     CRC32    -> 4-byte crc; no output

import (
	"bufio"
	"encoding/binary"
	"fmt"
	"io"
)

const sparseMagic = 0xed26ff3a

const (
	chunkRaw      = 0xCAC1
	chunkFill     = 0xCAC2
	chunkDontCare = 0xCAC3
	chunkCRC32    = 0xCAC4
)

// IsSparse reports whether the first 4 bytes are the sparse magic. It
// reads from r; callers that must not consume r should pass a peeker.
func isSparseMagic(b []byte) bool {
	return len(b) >= 4 && binary.LittleEndian.Uint32(b) == sparseMagic
}

// MaybeSparseReader returns a reader over the RAW image. If src is an
// Android sparse image it is expanded on the fly; otherwise src is
// returned unchanged. It buffers src to peek the magic without consuming
// it for the non-sparse case.
func MaybeSparseReader(src io.Reader) (io.Reader, error) {
	br := bufio.NewReaderSize(src, 32<<10)
	magic, err := br.Peek(4)
	if err != nil {
		if err == io.EOF {
			return br, nil // too short to be sparse; let downstream handle it
		}
		return nil, err
	}
	if !isSparseMagic(magic) {
		return br, nil
	}
	return newSparseReader(br)
}

type sparseReader struct {
	src        *bufio.Reader
	blkSz      uint32
	chunksLeft uint32

	// pending output for the current chunk
	emit func(p []byte) (int, error) // produces this chunk's bytes
	rem  int64                       // bytes left in the current chunk
	fill [4]byte                     // FILL pattern
	fillPos int
}

func newSparseReader(br *bufio.Reader) (*sparseReader, error) {
	var h struct {
		Magic       uint32
		Major       uint16
		Minor       uint16
		FileHdrSz   uint16
		ChunkHdrSz  uint16
		BlkSz       uint32
		TotalBlks   uint32
		TotalChunks uint32
		Checksum    uint32
	}
	if err := binary.Read(br, binary.LittleEndian, &h); err != nil {
		return nil, fmt.Errorf("sparse: read header: %w", err)
	}
	if h.Magic != sparseMagic {
		return nil, fmt.Errorf("sparse: bad magic %#x", h.Magic)
	}
	if h.BlkSz == 0 || h.BlkSz%4 != 0 {
		return nil, fmt.Errorf("sparse: invalid block size %d", h.BlkSz)
	}
	// Skip any extra header bytes the producer declared beyond the 28 we read.
	if extra := int(h.FileHdrSz) - 28; extra > 0 {
		if _, err := io.CopyN(io.Discard, br, int64(extra)); err != nil {
			return nil, fmt.Errorf("sparse: skip header tail: %w", err)
		}
	}
	return &sparseReader{src: br, blkSz: h.BlkSz, chunksLeft: h.TotalChunks}, nil
}

func (s *sparseReader) Read(p []byte) (int, error) {
	for {
		if s.rem > 0 {
			return s.emit(p)
		}
		if s.chunksLeft == 0 {
			return 0, io.EOF
		}
		if err := s.nextChunk(); err != nil {
			return 0, err
		}
	}
}

func (s *sparseReader) nextChunk() error {
	var ch struct {
		Type    uint16
		Resv    uint16
		Blks    uint32
		TotalSz uint32
	}
	if err := binary.Read(s.src, binary.LittleEndian, &ch); err != nil {
		return fmt.Errorf("sparse: read chunk header: %w", err)
	}
	s.chunksLeft--
	outBytes := int64(ch.Blks) * int64(s.blkSz)
	payload := int64(ch.TotalSz) - 12

	switch ch.Type {
	case chunkRaw:
		if payload != outBytes {
			return fmt.Errorf("sparse: raw chunk payload %d != output %d", payload, outBytes)
		}
		s.rem = outBytes
		s.emit = s.emitRaw
	case chunkFill:
		if payload != 4 {
			return fmt.Errorf("sparse: fill chunk payload %d != 4", payload)
		}
		if _, err := io.ReadFull(s.src, s.fill[:]); err != nil {
			return fmt.Errorf("sparse: read fill pattern: %w", err)
		}
		s.rem = outBytes
		s.fillPos = 0
		s.emit = s.emitFill
	case chunkDontCare:
		if payload != 0 {
			// Some producers store a payload they don't use; discard it.
			if _, err := io.CopyN(io.Discard, s.src, payload); err != nil {
				return fmt.Errorf("sparse: skip dontcare payload: %w", err)
			}
		}
		s.rem = outBytes
		s.emit = s.emitZero
	case chunkCRC32:
		if _, err := io.CopyN(io.Discard, s.src, payload); err != nil {
			return fmt.Errorf("sparse: skip crc32: %w", err)
		}
		s.rem = 0 // no output
	default:
		return fmt.Errorf("sparse: unknown chunk type %#x", ch.Type)
	}
	return nil
}

func (s *sparseReader) emitRaw(p []byte) (int, error) {
	n := int64(len(p))
	if n > s.rem {
		n = s.rem
	}
	r, err := s.src.Read(p[:n])
	s.rem -= int64(r)
	if err == io.EOF && s.rem > 0 {
		err = io.ErrUnexpectedEOF
	}
	return r, err
}

func (s *sparseReader) emitFill(p []byte) (int, error) {
	n := int64(len(p))
	if n > s.rem {
		n = s.rem
	}
	for i := int64(0); i < n; i++ {
		p[i] = s.fill[s.fillPos]
		s.fillPos = (s.fillPos + 1) & 3
	}
	s.rem -= n
	return int(n), nil
}

func (s *sparseReader) emitZero(p []byte) (int, error) {
	n := int64(len(p))
	if n > s.rem {
		n = s.rem
	}
	for i := int64(0); i < n; i++ {
		p[i] = 0
	}
	s.rem -= n
	return int(n), nil
}
