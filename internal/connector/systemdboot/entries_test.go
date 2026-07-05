package systemdboot

import "testing"

func TestParseCounter(t *testing.T) {
	for _, tc := range []struct {
		name       string
		left, done int
	}{
		{"slot-a.conf", noCounter, 0},
		{"slot-a+3.conf", 3, 0},
		{"slot-a+2-1.conf", 2, 1},
		{"slot-b+0-3.conf", 0, 3},
		{"slot-a+bogus.conf", noCounter, 0}, // unparseable -> no counter
		{"slot-a+1-x.conf", noCounter, 0},   // unparseable done -> no counter
	} {
		left, done := parseCounter(tc.name)
		if left != tc.left || done != tc.done {
			t.Errorf("parseCounter(%q) = (%d,%d); want (%d,%d)", tc.name, left, done, tc.left, tc.done)
		}
	}
}

func TestCounterFilename(t *testing.T) {
	for _, tc := range []struct {
		letter     string
		left, done int
		want       string
	}{
		{"a", noCounter, 0, "slot-a.conf"},
		{"a", 3, 0, "slot-a+3.conf"},
		{"b", 2, 1, "slot-b+2-1.conf"},
		{"b", 0, 3, "slot-b+0-3.conf"},
	} {
		if got := counterFilename(tc.letter, tc.left, tc.done); got != tc.want {
			t.Errorf("counterFilename(%q,%d,%d) = %q; want %q", tc.letter, tc.left, tc.done, got, tc.want)
		}
	}
}

func TestMatchesSlot(t *testing.T) {
	for _, tc := range []struct {
		name, id string
		want     bool
	}{
		{"slot-a.conf", "slot-a", true},
		{"slot-a+3.conf", "slot-a", true},
		{"slot-a+2-1.conf", "slot-a", true},
		{"slot-b.conf", "slot-a", false},
		{"slot-alpha.conf", "slot-a", false}, // prefix collision must not match
	} {
		if got := matchesSlot(tc.name, tc.id); got != tc.want {
			t.Errorf("matchesSlot(%q,%q) = %v; want %v", tc.name, tc.id, got, tc.want)
		}
	}
}

func TestEntryClassifiers(t *testing.T) {
	good := entry{left: noCounter}
	if good.hasCounter() || good.isBad() {
		t.Fatal("counter-less entry must be neither counted nor bad")
	}
	trial := entry{left: 2, done: 1}
	if !trial.hasCounter() || trial.isBad() {
		t.Fatal("live-counter entry must be counted and not bad")
	}
	bad := entry{left: 0, done: 3}
	if !bad.hasCounter() || !bad.isBad() {
		t.Fatal("exhausted entry must be counted and bad")
	}
}
