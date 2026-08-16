package tegrauefi

import "testing"

// l4tVersionLabel decodes the packed FMP firmware version that meta-tegra's
// oe4t.uefi.get_hex_version() builds from L4T_VERSION:
//
//	0x%02x%02x%02x%02x % (branch >> 8, branch & 0xff, major, minor)
//
// The branch is 16 bits wide, so a branch >= 256 must not bleed into the
// major field.
func TestL4TVersionLabel(t *testing.T) {
	for _, tc := range []struct {
		name string
		raw  string
		want string
	}{
		{
			// Measured on an r39.2 Thor: both fw_version and, after a capsule
			// apply, lowest_supported_fw_version read 2556416.
			name: "r39.2.0 as reported on device",
			raw:  "2556416",
			want: "39.2.0 (2556416)",
		},
		{
			// 0x00260400 — the release a downgrade would target.
			name: "r38.4.0",
			raw:  "2491392",
			want: "38.4.0 (2491392)",
		},
		{
			// FmpDxe's DEFAULT_LOWESTSUPPORTEDVERSION: no floor enforced.
			name: "zero means no floor",
			raw:  "0",
			want: "0 (none)",
		},
		{
			// 0x01000300: branch 256 must decode as the branch, not overflow
			// into major. This is the case an 8-bit decode gets wrong.
			name: "branch above 255 stays in the branch field",
			raw:  "16777984",
			want: "256.3.0 (16777984)",
		},
		{
			name: "unparseable input passes through untouched",
			raw:  "not-a-number",
			want: "not-a-number",
		},
		{
			name: "empty input passes through untouched",
			raw:  "",
			want: "",
		},
		{
			// Wider than uint32: pass through rather than truncate.
			name: "out of range passes through untouched",
			raw:  "4294967296",
			want: "4294967296",
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if got := l4tVersionLabel(tc.raw); got != tc.want {
				t.Errorf("l4tVersionLabel(%q) = %q, want %q", tc.raw, got, tc.want)
			}
		})
	}
}
