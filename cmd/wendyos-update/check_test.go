package main

import (
	"errors"
	"fmt"
	"strings"
	"testing"

	"github.com/wendylabsinc/wendyos-update/internal/connector"
)

// The message must name what failed. A caller reading stderr should not have
// to re-run with --json to find out which check tripped, so a generic
// "device is not ready" is not good enough.
func TestNotReadyErrorNamesTheFailures(t *testing.T) {
	for _, tc := range []struct {
		name   string
		failed []connector.Check
		want   string
	}{
		{
			name: "single failure reads as the check itself",
			failed: []connector.Check{{
				Name:   "ESP capsule headroom",
				Detail: "the ESP (/boot/efi) has 1024 bytes free but staging needs 22325239",
			}},
			want: "ESP capsule headroom: the ESP (/boot/efi) has 1024 bytes free but staging needs 22325239",
		},
		{
			name: "several failures are counted and joined",
			failed: []connector.Check{
				{Name: "no update pending", Detail: "artifact-x is pending in phase \"swapped\" for slot B"},
				{Name: "ESP capsule headroom", Detail: "no room"},
			},
			want: `2 checks failed — no update pending: artifact-x is pending in phase "swapped" for slot B; ESP capsule headroom: no room`,
		},
		{
			name:   "a detail-less check still names itself",
			failed: []connector.Check{{Name: "rootfs A/B redundancy"}},
			want:   "rootfs A/B redundancy",
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			got := (&notReadyError{failed: tc.failed}).Error()
			if got != tc.want {
				t.Errorf("Error() = %q, want %q", got, tc.want)
			}
			if strings.Contains(got, "not ready") {
				t.Errorf("Error() fell back to a generic message: %q", got)
			}
		})
	}
}

// The verdict maps to its own exit code, so a caller can tell "the device is
// not ready" from "the tool broke". It must survive wrapping.
func TestNotReadyErrorExitCode(t *testing.T) {
	err := &notReadyError{failed: []connector.Check{{Name: "ESP capsule headroom", Detail: "no room"}}}
	if got := exitCode(err); got != exitNotReady {
		t.Errorf("exitCode(notReadyError) = %d, want %d", got, exitNotReady)
	}
	if got := exitCode(fmt.Errorf("check: %w", err)); got != exitNotReady {
		t.Errorf("exitCode(wrapped) = %d, want %d", got, exitNotReady)
	}
	if got := exitCode(errors.New("something else")); got != exitError {
		t.Errorf("exitCode(generic) = %d, want %d", got, exitError)
	}
}
