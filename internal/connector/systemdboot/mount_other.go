//go:build !linux

package systemdboot

import "fmt"

// defaultMount is a stub on non-Linux hosts: the connector only runs on the
// Jetson (Linux) device, but keeping the package buildable off-target lets the
// unit tests (which inject their own mountFn) run natively during development.
func defaultMount(dev string) (string, func(), error) {
	return "", nil, fmt.Errorf("systemdboot: mounting a slot rootfs is only supported on linux (dev=%s)", dev)
}
