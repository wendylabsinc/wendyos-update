// Update phase — the value carried in `State.phase` (a `String`, matching
// Go's `engine.Phase` which is a `type Phase string`). Ports the phase
// constants in internal/engine/state.go.
//
// `State.phase` is a plain `String` (Model, Task 2.1), so these are exposed
// as `String` constants rather than a distinct enum type: downstream
// install/commit/verify-boot tasks compare and assign `State.phase` against
// these names, and keeping them as strings avoids a conversion layer at
// every such call site.

/// Payload verified on the inactive slot, swap not yet done.
public let PhaseWritten = "written"

/// Slot swapped (or capsule staged); reboot pending, or commit pending
/// after reboot.
public let PhaseSwapped = "swapped"

/// The verify unit (or commit) marked the deployment failed.
public let PhaseFailed = "failed"
