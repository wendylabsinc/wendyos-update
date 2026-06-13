// Package artifact reads .wendy update artifacts.
// Format: docs/manifest-schema.md (v1, frozen). A .wendy file is a tar
// with manifest.json FIRST, then the compressed payload — designed for
// one streaming pass from a URL.
package artifact

import "fmt"

// sha256HexLen is the length of a SHA-256 digest in lowercase hex.
const sha256HexLen = 64

// Manifest is the parsed manifest.json (format v1).
type Manifest struct {
	FormatVersion     int      `json:"format_version"`
	ArtifactName      string   `json:"artifact_name"`
	ArtifactVersion   string   `json:"artifact_version"`
	CompatibleDevices []string `json:"compatible_devices"`
	Payload           Payload  `json:"payload"`
	BootloaderUpdate  bool     `json:"bootloader_update"`
	MinToolVersion    string   `json:"min_tool_version"`
}

// Payload describes the rootfs image member.
type Payload struct {
	Name             string `json:"name"`
	Size             int64  `json:"size"`
	SHA256           string `json:"sha256"`            // uncompressed image
	CompressedSHA256 string `json:"compressed_sha256"` // tar member as stored
	Compression      string `json:"compression"`       // "zstd" | "gzip" | "none"
}

// CompatibleWith reports whether the artifact targets the given device
// type (from /etc/wendyos/device-type).
func (m *Manifest) CompatibleWith(deviceType string) bool {
	for _, d := range m.CompatibleDevices {
		if d == deviceType {
			return true
		}
	}
	return false
}

// Validate checks structural validity of a parsed manifest (format v1).
// Device compatibility and tool-version gating are policy checks the
// engine performs separately — this is "is the manifest well-formed".
func (m *Manifest) Validate() error {
	if m.FormatVersion != 1 {
		return fmt.Errorf("unsupported format_version %d (tool supports 1)", m.FormatVersion)
	}
	if m.ArtifactName == "" || m.ArtifactVersion == "" {
		return fmt.Errorf("artifact_name and artifact_version are required")
	}
	if len(m.CompatibleDevices) == 0 {
		return fmt.Errorf("compatible_devices must not be empty")
	}
	if m.Payload.Name == "" {
		return fmt.Errorf("payload.name is required")
	}
	if len(m.Payload.SHA256) != sha256HexLen {
		return fmt.Errorf("payload.sha256 must be a hex sha256 digest")
	}
	switch m.Payload.Compression {
	case "zstd", "gzip", "none":
	default:
		return fmt.Errorf("unsupported payload.compression %q", m.Payload.Compression)
	}
	return nil
}
