package connector

import (
	"fmt"
	"sort"
)

// Factory creates a connector. Detect reports whether this connector's
// platform is present — it must be cheap and must not mutate anything.
type Factory struct {
	New    func() Connector
	Detect func() bool
}

var registry = map[string]Factory{}

// Register adds a connector factory under its name. Called from
// connector packages' init(); duplicate names are a programming error.
func Register(name string, f Factory) {
	if _, dup := registry[name]; dup {
		panic("connector: duplicate registration: " + name)
	}
	registry[name] = f
}

// Select resolves a connector. Order (docs/connector-architecture.md):
//  1. explicit name (from /etc/wendy-update/config.json) — must exist
//  2. auto-detect across registered connectors — exactly one must match
//  3. otherwise a hard error: never guess on an OTA path.
func Select(explicit string) (Connector, error) {
	if explicit != "" {
		f, ok := registry[explicit]
		if !ok {
			return nil, fmt.Errorf("connector %q not built into this binary (have: %v)", explicit, names())
		}
		return f.New(), nil
	}

	var matches []string
	for name, f := range registry {
		if f.Detect() {
			matches = append(matches, name)
		}
	}
	switch len(matches) {
	case 1:
		return registry[matches[0]].New(), nil
	case 0:
		return nil, fmt.Errorf("no connector detected this platform (have: %v); set one in /etc/wendy-update/config.json", names())
	default:
		sort.Strings(matches)
		return nil, fmt.Errorf("ambiguous platform: connectors %v all match; set one in /etc/wendy-update/config.json", matches)
	}
}

func names() []string {
	n := make([]string, 0, len(registry))
	for name := range registry {
		n = append(n, name)
	}
	sort.Strings(n)
	return n
}
