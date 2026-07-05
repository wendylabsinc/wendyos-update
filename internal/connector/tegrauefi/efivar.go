package tegrauefi

// efivarfs access for the NVIDIA RootfsStatusSlot variables.
//
// Validated variable format (t234/r36, t264/r38, and Orin Nano t234/r39.2 —
// the last read directly off the device for WDY-1742, identical 8-byte layout):
//   bytes 0..3  EFI attributes, 0x07 = NV+BS+RT (little-endian uint32)
//   bytes 4..7  status (little-endian uint32): 0 = normal, 0xFF = unbootable
//
// Writing attrs(0x07) + status(0) in a single 8-byte write resets a slot
// to normal AND re-seeds the firmware retry budget (observed on Thor:
// retry_count back to 3). efivarfs marks variables immutable by default,
// so the immutable inode flag must be cleared before writing — the
// chattr -i equivalent, done natively via FS_IOC_GETFLAGS/SETFLAGS.

import (
	"fmt"
	"os"

	"golang.org/x/sys/unix"
)

// statusNormal is the full 8-byte payload that rehabilitates a slot.
var statusNormal = []byte{0x07, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00}

// fsImmutableFL is FS_IMMUTABLE_FL from linux/fs.h (not exported by
// golang.org/x/sys/unix).
const fsImmutableFL = 0x00000010

// readStatus returns the raw variable content. A valid status var is
// exactly 8 bytes; callers check size themselves (the JP6 incident
// involved a wrong-sized variable).
func readStatus(path string) ([]byte, error) {
	return os.ReadFile(path)
}

// statusIsWellFormed reports whether raw is the validated 8-byte
// attrs+status layout. Confirmed identical on t234/r36, t264/r38, and Orin
// Nano t234/r39.2 (read off the device for WDY-1742). A different size is a
// layout we have NOT validated on this board: BootIsCompromised treats it as
// inconclusive rather than compromised, so the documented JP6 wrong-sized
// variable cannot force a false rollback. The engine's running-slot vs
// target-slot check and the ESRT cascade remain the authoritative guards.
func statusIsWellFormed(raw []byte) bool {
	return len(raw) == 8
}

// statusIsNormal reports whether raw content is a well-formed
// "normal" status variable (size 8, all four status bytes zero).
func statusIsNormal(raw []byte) bool {
	if !statusIsWellFormed(raw) {
		return false
	}
	return raw[4] == 0 && raw[5] == 0 && raw[6] == 0 && raw[7] == 0
}

// clearImmutable removes the immutable inode flag (efivarfs sets it by
// default). Filesystems without flag support (e.g. tmpfs in tests)
// return ENOTTY/EOPNOTSUPP — treated as "nothing to clear".
func clearImmutable(path string) error {
	f, err := os.OpenFile(path, os.O_RDONLY, 0)
	if err != nil {
		return err
	}
	defer f.Close()

	flags, err := unix.IoctlGetInt(int(f.Fd()), unix.FS_IOC_GETFLAGS)
	if err != nil {
		if err == unix.ENOTTY || err == unix.EOPNOTSUPP || err == unix.ENOSYS {
			return nil
		}
		return fmt.Errorf("get inode flags: %w", err)
	}
	if flags&fsImmutableFL == 0 {
		return nil
	}
	flags &^= fsImmutableFL
	if err := unix.IoctlSetPointerInt(int(f.Fd()), unix.FS_IOC_SETFLAGS, flags); err != nil {
		return fmt.Errorf("clear immutable flag: %w", err)
	}
	return nil
}

// writeStatusNormal writes the 8-byte normal payload in a single
// write(2), matching the validated dd pattern, then verifies read-back.
func writeStatusNormal(path string) error {
	if err := writeVar(path, statusNormal); err != nil {
		return fmt.Errorf("status var: %w", err)
	}
	raw, err := readStatus(path)
	if err != nil {
		return fmt.Errorf("read-back: %w", err)
	}
	if !statusIsNormal(raw) {
		return fmt.Errorf("read-back mismatch: % x", raw)
	}
	return nil
}

// writeVar writes a complete efivar payload (attrs + data) in a single
// write(2), clearing the immutable flag first if the variable exists.
func writeVar(path string, payload []byte) error {
	if _, err := os.Stat(path); err == nil {
		if err := clearImmutable(path); err != nil {
			return err
		}
	}
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE, 0o644)
	if err != nil {
		return err
	}
	if _, err := f.Write(payload); err != nil {
		f.Close()
		return fmt.Errorf("write: %w", err)
	}
	if err := f.Close(); err != nil {
		return fmt.Errorf("close: %w", err)
	}
	return nil
}

// osIndicationsProcessCapsule is bit 2 of the OsIndications UINT64:
// "process capsule(s) on next boot". Validated on Thor: armed variable
// reads 07 00 00 00 04 00 00 00 00 00 00 00 (4-byte attrs + UINT64).
//
// The SAME bit in the companion OsIndicationsSupported variable is the
// firmware's capability signal: it means FILE_CAPSULE_DELIVERY (capsule-on-disk)
// is supported. Both variables share the 4-byte-attrs + UINT64 layout, so
// byte[4] carries bits 0..7.
const osIndicationsProcessCapsule = 0x04

// firmwareSupportsCapsuleOnDisk reports whether the firmware advertises
// FILE_CAPSULE_DELIVERY in OsIndicationsSupported. Absent, unreadable, or a
// short variable → not supported. Verified on-device: Orin Nano t234/r39.2
// reads 06 00 00 00 45 ... (bit 2 set) and Thor t264/r38 likewise.
func firmwareSupportsCapsuleOnDisk(path string) bool {
	raw, err := os.ReadFile(path)
	if err != nil || len(raw) < 5 {
		return false
	}
	return raw[4]&osIndicationsProcessCapsule != 0
}

// clearOsIndicationsCapsuleBit disarms capsule processing (rollback
// before reboot). Preserves other bits; a missing variable is a no-op.
func clearOsIndicationsCapsuleBit(path string) error {
	raw, err := os.ReadFile(path)
	if os.IsNotExist(err) {
		return nil
	}
	if err != nil {
		return fmt.Errorf("OsIndications: %w", err)
	}
	if len(raw) < 5 || raw[4]&osIndicationsProcessCapsule == 0 {
		return nil // bit not set
	}
	var value uint64
	for i := 0; i < 8 && 4+i < len(raw); i++ {
		value |= uint64(raw[4+i]) << (8 * i)
	}
	value &^= osIndicationsProcessCapsule

	payload := make([]byte, 12)
	payload[0] = 0x07
	for i := 0; i < 8; i++ {
		payload[4+i] = byte(value >> (8 * i))
	}
	if err := writeVar(path, payload); err != nil {
		return fmt.Errorf("OsIndications: %w", err)
	}
	return nil
}

// setOsIndicationsCapsuleBit sets bit 2, preserving any other bits the
// variable already carries, then verifies the bit reads back. Port of
// oe4t-set-uefi-OSIndications + switch-rootfs verify_osindications.
func setOsIndicationsCapsuleBit(path string) error {
	var value uint64
	if raw, err := os.ReadFile(path); err == nil && len(raw) >= 5 {
		for i := 0; i < 8 && 4+i < len(raw); i++ {
			value |= uint64(raw[4+i]) << (8 * i)
		}
	} // absent or malformed: start from 0, the write creates it

	value |= osIndicationsProcessCapsule

	payload := make([]byte, 12)
	payload[0] = 0x07 // NV+BS+RT
	for i := 0; i < 8; i++ {
		payload[4+i] = byte(value >> (8 * i))
	}
	if err := writeVar(path, payload); err != nil {
		return fmt.Errorf("OsIndications: %w", err)
	}

	raw, err := os.ReadFile(path)
	if err != nil {
		return fmt.Errorf("OsIndications read-back: %w", err)
	}
	if len(raw) < 5 || raw[4]&osIndicationsProcessCapsule == 0 {
		return fmt.Errorf("OsIndications read-back: capsule bit not set (% x)", raw)
	}
	return nil
}
