// Package log is wendyos-update's output layer. It renders structured
// slog records and coarse install progress to a single writer (stderr),
// adapting the format to where the tool is running:
//
//   - interactive terminal: colored lines + an in-place progress bar (\r)
//   - under systemd/journald: plain lines carrying sd-daemon "<N>"
//     severity prefixes that journald parses into PRIORITY
//   - piped/redirected: plain timestamped lines
//
// stdout is NOT touched here — it stays the machine-readable JSON channel
// of the CLI contract (docs/cli-contract.md). Everything in this package
// goes to stderr.
//
// Install it once in main:
//
//	ui := log.New(os.Stderr, log.Detect(os.Stderr))
//	slog.SetDefault(ui.Slog())
//
// after which engine and connector code logs via the slog package
// functions, and the CLI drives the progress bar via ui.Progress.
package log

import (
	"context"
	"fmt"
	"io"
	"log/slog"
	"os"
	"strings"
	"sync"
	"time"

	"golang.org/x/sys/unix"
)

// Mode selects how records and progress are rendered.
type Mode int

const (
	// ModePlain prints plain timestamped lines (piped or redirected,
	// no journal). This is the safe default.
	ModePlain Mode = iota
	// ModeTTY is an interactive terminal: colored lines and an in-place
	// progress bar updated with carriage returns.
	ModeTTY
	// ModeJournal is running under systemd: lines carry sd-daemon "<N>"
	// severity prefixes (journald turns them into PRIORITY) and progress
	// is emitted as discrete, throttled lines (a \r bar is meaningless in
	// the journal).
	ModeJournal
)

// msgPrefix tags every line so wendyos-update's output is greppable when
// interleaved with other services in the journal.
const msgPrefix = "wendyos-update: "

// IsTTY reports whether f is a terminal.
func IsTTY(f *os.File) bool {
	if f == nil {
		return false
	}
	_, err := unix.IoctlGetTermios(int(f.Fd()), unix.TCGETS)
	return err == nil
}

// Detect picks a Mode for output going to w (normally stderr). systemd's
// $JOURNAL_STREAM is the canonical "I am a service" signal and wins; then
// a TTY means interactive; otherwise plain.
func Detect(w *os.File) Mode {
	if os.Getenv("JOURNAL_STREAM") != "" {
		return ModeJournal
	}
	if IsTTY(w) {
		return ModeTTY
	}
	return ModePlain
}

// Logger serializes slog records and progress updates onto one writer so
// an in-place progress bar and log lines never corrupt one another.
type Logger struct {
	w     io.Writer
	mode  Mode
	debug bool // emit Debug-level records (WENDY_DEBUG)

	mu        sync.Mutex
	barActive bool // an unterminated \r progress line is on screen
}

// New builds a Logger writing to w in the given mode.
func New(w io.Writer, mode Mode) *Logger {
	return &Logger{
		w:     w,
		mode:  mode,
		debug: os.Getenv("WENDY_DEBUG") != "",
	}
}

// Slog returns a *slog.Logger backed by this Logger. Install it with
// slog.SetDefault so the whole tool logs through here.
func (l *Logger) Slog() *slog.Logger { return slog.New(&handler{l: l}) }

func (l *Logger) colorize() bool {
	return l.mode == ModeTTY && os.Getenv("NO_COLOR") == ""
}

// writeLineLocked emits one complete log line, first clearing any active
// progress bar so it is not left half-overwritten.
func (l *Logger) writeLineLocked(level slog.Level, msg string) {
	l.clearBarLocked()

	var b strings.Builder
	switch l.mode {
	case ModeJournal:
		b.WriteString(sevPrefix(level))
		b.WriteString(msgPrefix)
		b.WriteString(msg)
	case ModeTTY:
		if c := colorFor(level); c != "" && l.colorize() {
			b.WriteString(c)
			b.WriteString(msgPrefix)
			b.WriteString(msg)
			b.WriteString(colorReset)
		} else {
			b.WriteString(msgPrefix)
			b.WriteString(msg)
		}
	default: // ModePlain
		b.WriteString(time.Now().Format(time.RFC3339))
		b.WriteByte(' ')
		b.WriteString(levelText(level))
		b.WriteByte(' ')
		b.WriteString(msgPrefix)
		b.WriteString(msg)
	}
	b.WriteByte('\n')
	io.WriteString(l.w, b.String())
}

// clearBarLocked erases an in-place progress line (TTY only; barActive is
// never set in the other modes).
func (l *Logger) clearBarLocked() {
	if l.barActive {
		io.WriteString(l.w, "\r\033[K")
		l.barActive = false
	}
}

const barWidth = 30

// Progress renders a coarse install progress update. percent < 0 means
// indeterminate. The in-place bar is an interactive nicety, so it is drawn
// ONLY on a TTY. Under journald or when piped/redirected, per-percent
// updates are noise — the phase transitions are already logged (downloading
// / writing / verifying) and install emits a write-throughput line — so
// Progress is a no-op there.
func (l *Logger) Progress(phase string, percent int) {
	if l.mode != ModeTTY {
		return
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	l.renderBarLocked(phase, percent)
}

func (l *Logger) renderBarLocked(phase string, percent int) {
	var content string
	if percent < 0 {
		content = fmt.Sprintf("%s%s…", msgPrefix, phase)
	} else {
		filled := percent * barWidth / 100
		if filled > barWidth {
			filled = barWidth
		}
		bar := strings.Repeat("█", filled) + strings.Repeat("░", barWidth-filled)
		content = fmt.Sprintf("%s%-8s [%s] %3d%%", msgPrefix, phase, bar, percent)
	}
	// \r to the line start, content, then \033[K to wipe any leftover of a
	// previously longer line.
	io.WriteString(l.w, "\r"+content+"\033[K")
	l.barActive = true
	if percent >= 100 {
		io.WriteString(l.w, "\n")
		l.barActive = false
	}
}

// handler is the slog.Handler that funnels records through Logger.
type handler struct {
	l      *Logger
	attrs  []slog.Attr
	groups []string
}

func (h *handler) Enabled(_ context.Context, level slog.Level) bool {
	if level < slog.LevelInfo {
		return h.l.debug
	}
	return true
}

func (h *handler) Handle(_ context.Context, r slog.Record) error {
	var b strings.Builder
	b.WriteString(r.Message)

	writeAttr := func(a slog.Attr) bool {
		if a.Equal(slog.Attr{}) {
			return true
		}
		b.WriteByte(' ')
		if len(h.groups) > 0 {
			b.WriteString(strings.Join(h.groups, "."))
			b.WriteByte('.')
		}
		b.WriteString(a.Key)
		b.WriteByte('=')
		b.WriteString(a.Value.Resolve().String())
		return true
	}
	for _, a := range h.attrs {
		writeAttr(a)
	}
	r.Attrs(writeAttr)

	h.l.mu.Lock()
	defer h.l.mu.Unlock()
	h.l.writeLineLocked(r.Level, b.String())
	return nil
}

func (h *handler) WithAttrs(as []slog.Attr) slog.Handler {
	nh := *h
	nh.attrs = append(append([]slog.Attr{}, h.attrs...), as...)
	return &nh
}

func (h *handler) WithGroup(name string) slog.Handler {
	if name == "" {
		return h
	}
	nh := *h
	nh.groups = append(append([]string{}, h.groups...), name)
	return &nh
}

// sevPrefix maps a slog level to an sd-daemon severity prefix. journald
// (and the kmsg/syslog console) parse a leading "<N>" into PRIORITY.
func sevPrefix(level slog.Level) string {
	switch {
	case level >= slog.LevelError:
		return "<3>" // err
	case level >= slog.LevelWarn:
		return "<4>" // warning
	case level >= slog.LevelInfo:
		return "<6>" // info
	default:
		return "<7>" // debug
	}
}

func levelText(level slog.Level) string {
	switch {
	case level >= slog.LevelError:
		return "ERROR"
	case level >= slog.LevelWarn:
		return "WARN"
	case level >= slog.LevelInfo:
		return "INFO"
	default:
		return "DEBUG"
	}
}

const colorReset = "\033[0m"

func colorFor(level slog.Level) string {
	switch {
	case level >= slog.LevelError:
		return "\033[31m" // red
	case level >= slog.LevelWarn:
		return "\033[33m" // yellow
	default:
		return "" // info/debug keep the terminal default
	}
}
