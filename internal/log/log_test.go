package log

import (
	"bytes"
	"log/slog"
	"strings"
	"testing"
)

// newCaptured returns a Logger in the given mode writing to a buffer,
// plus a *slog.Logger wired to it.
func newCaptured(mode Mode) (*Logger, *slog.Logger, *bytes.Buffer) {
	var buf bytes.Buffer
	l := New(&buf, mode)
	return l, l.Slog(), &buf
}

func TestJournalSeverityPrefix(t *testing.T) {
	_, lg, buf := newCaptured(ModeJournal)
	lg.Info("writing slot", "dev", "/dev/nvme0n1p2")
	lg.Warn("ESRT not readable")
	lg.Error("commit failed")

	out := buf.String()
	lines := strings.Split(strings.TrimRight(out, "\n"), "\n")
	if len(lines) != 3 {
		t.Fatalf("want 3 lines, got %d: %q", len(lines), out)
	}
	want := []string{
		"<6>wendyos-update: writing slot dev=/dev/nvme0n1p2",
		"<4>wendyos-update: ESRT not readable",
		"<3>wendyos-update: commit failed",
	}
	for i, w := range want {
		if lines[i] != w {
			t.Errorf("line %d:\n  got  %q\n  want %q", i, lines[i], w)
		}
	}
}

func TestJournalProgressIsSuppressed(t *testing.T) {
	// The progress bar is interactive-only: in journal mode Progress is a
	// no-op (the journal gets the phase-transition log lines instead, not
	// per-percent noise, and never a \r bar).
	l, _, buf := newCaptured(ModeJournal)
	for pct := 0; pct <= 100; pct += 5 {
		l.Progress("write", pct)
	}
	if out := buf.String(); out != "" {
		t.Fatalf("journal progress should emit nothing, got:\n%q", out)
	}
}

func TestPlainProgressIsSuppressed(t *testing.T) {
	// Same for piped/redirected output.
	l, _, buf := newCaptured(ModePlain)
	l.Progress("write", 50)
	l.Progress("write", 100)
	if out := buf.String(); out != "" {
		t.Fatalf("plain progress should emit nothing, got:\n%q", out)
	}
}

func TestTTYProgressUsesCarriageReturn(t *testing.T) {
	l, _, buf := newCaptured(ModeTTY)
	l.Progress("write", 10)
	l.Progress("write", 100)
	out := buf.String()
	if !strings.Contains(out, "\r") {
		t.Errorf("TTY progress should use \\r:\n%q", out)
	}
	if !strings.HasSuffix(out, "\n") {
		t.Errorf("TTY progress should terminate with newline at 100%%:\n%q", out)
	}
	if !strings.Contains(out, "100%") {
		t.Errorf("missing percentage:\n%q", out)
	}
}

func TestTTYLogClearsActiveBar(t *testing.T) {
	// A log line emitted mid-progress must first clear the bar (\r\033[K)
	// so the two do not overlap on the terminal.
	l, lg, buf := newCaptured(ModeTTY)
	l.Progress("write", 40) // leaves an active bar (no trailing newline)
	lg.Info("verifying payload")
	out := buf.String()
	if !strings.Contains(out, "\r\033[K") {
		t.Errorf("log during active bar should emit clear sequence \\r\\033[K:\n%q", out)
	}
}

func TestPlainModeHasLevelNoPrefix(t *testing.T) {
	_, lg, buf := newCaptured(ModePlain)
	lg.Info("hello")
	out := buf.String()
	if strings.HasPrefix(out, "<") {
		t.Errorf("plain mode must not emit sd-daemon prefix:\n%q", out)
	}
	if !strings.Contains(out, "INFO") || !strings.Contains(out, "wendyos-update: hello") {
		t.Errorf("plain line missing level or message:\n%q", out)
	}
}

func TestDebugGatedByEnv(t *testing.T) {
	// Default Logger (debug=false): Debug records are dropped.
	_, lg, buf := newCaptured(ModeJournal)
	lg.Debug("verbose detail")
	if buf.Len() != 0 {
		t.Errorf("debug should be suppressed by default, got: %q", buf.String())
	}

	// With debug enabled it is emitted at PRIORITY 7.
	var b bytes.Buffer
	dl := New(&b, ModeJournal)
	dl.debug = true
	dl.Slog().Debug("verbose detail")
	if !strings.HasPrefix(b.String(), "<7>") {
		t.Errorf("debug line should carry <7> prefix:\n%q", b.String())
	}
}

func TestWithAttrs(t *testing.T) {
	_, lg, buf := newCaptured(ModeJournal)
	lg.With("slot", "B").Info("activating")
	if !strings.Contains(buf.String(), "activating slot=B") {
		t.Errorf("WithAttrs not rendered:\n%q", buf.String())
	}
}
