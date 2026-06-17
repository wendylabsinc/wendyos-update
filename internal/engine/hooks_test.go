package engine

import (
	"errors"
	"os"
	"path/filepath"
	"testing"

	"github.com/wendylabsinc/wendyos-update/internal/connector"
)

func writeHook(t *testing.T, dir, name, body string) {
	t.Helper()
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, name), []byte("#!/bin/sh\n"+body+"\n"), 0o755); err != nil {
		t.Fatal(err)
	}
}

func TestHooksAbsentDirPasses(t *testing.T) {
	e := &Engine{HooksDir: t.TempDir()} // no <phase>.d subdir exists
	if err := e.runHooks(HookPreInstall, nil); err != nil {
		t.Fatalf("absent dir must pass: %v", err)
	}
}

func TestHooksEmptyDirPasses(t *testing.T) {
	root := t.TempDir()
	if err := os.MkdirAll(filepath.Join(root, HookHealth+".d"), 0o755); err != nil {
		t.Fatal(err)
	}
	e := &Engine{HooksDir: root}
	if err := e.runHooks(HookHealth, nil); err != nil {
		t.Fatalf("empty dir must pass: %v", err)
	}
}

func TestHooksAllPass(t *testing.T) {
	root := t.TempDir()
	d := filepath.Join(root, HookHealth+".d")
	writeHook(t, d, "10-ok", "exit 0")
	writeHook(t, d, "20-also-ok", "true")
	e := &Engine{HooksDir: root}
	if err := e.runHooks(HookHealth, nil); err != nil {
		t.Fatalf("all-passing hooks: %v", err)
	}
}

func TestHookFailureNamesPhaseAndHook(t *testing.T) {
	root := t.TempDir()
	d := filepath.Join(root, HookPreInstall+".d")
	writeHook(t, d, "10-ok", "exit 0")
	writeHook(t, d, "20-bad", "exit 1")
	e := &Engine{HooksDir: root}
	err := e.runHooks(HookPreInstall, nil)
	var he *HookError
	if !errors.As(err, &he) {
		t.Fatalf("want HookError, got %v", err)
	}
	if he.Hook != "20-bad" || he.Phase != HookPreInstall {
		t.Fatalf("wrong hook/phase: %q / %q", he.Hook, he.Phase)
	}
}

func TestHooksSkipsNonExecutable(t *testing.T) {
	root := t.TempDir()
	d := filepath.Join(root, HookHealth+".d")
	if err := os.MkdirAll(d, 0o755); err != nil {
		t.Fatal(err)
	}
	// a non-executable file that would fail if run — must be skipped
	if err := os.WriteFile(filepath.Join(d, "README"), []byte("not a hook\nexit 1\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	e := &Engine{HooksDir: root}
	if err := e.runHooks(HookHealth, nil); err != nil {
		t.Fatalf("non-executable files must be skipped: %v", err)
	}
}

func TestHooksLexicalOrderStopsAtFirstFailure(t *testing.T) {
	root := t.TempDir()
	d := filepath.Join(root, HookHealth+".d")
	marker := filepath.Join(t.TempDir(), "ran")
	writeHook(t, d, "10-fail", "exit 3")
	writeHook(t, d, "20-touch", "touch "+marker) // must NOT run
	e := &Engine{HooksDir: root}
	if err := e.runHooks(HookHealth, nil); err == nil {
		t.Fatal("expected failure")
	}
	if _, err := os.Stat(marker); !os.IsNotExist(err) {
		t.Fatal("later hook ran despite earlier failure")
	}
}

func TestHealthDirLegacyOverride(t *testing.T) {
	// the health phase still honours the legacy HealthDir override
	hd := t.TempDir()
	writeHook(t, hd, "10-bad", "exit 1")
	e := &Engine{HealthDir: hd}
	var he *HookError
	if !errors.As(e.runHooks(HookHealth, nil), &he) {
		t.Fatal("HealthDir override not used for health phase")
	}
}

func TestHookEnvExported(t *testing.T) {
	root := t.TempDir()
	d := filepath.Join(root, HookPreInstall+".d")
	// the hook exits non-zero unless it sees the expected WENDY_* env
	writeHook(t, d, "10-checkenv",
		`[ "$WENDY_PHASE" = pre-install ] && [ "$WENDY_ARTIFACT_NAME" = img ] && `+
			`[ "$WENDY_ARTIFACT_VERSION" = 1.2.3 ] && [ "$WENDY_TARGET_SLOT" = B ] && `+
			`[ "$WENDY_CURRENT_SLOT" = A ] && [ "$WENDY_BOOTLOADER_UPDATE" = false ]`)
	e := &Engine{HooksDir: root, StateDir: "/data/x"}
	env := e.hookEnv("img", "1.2.3", connector.SlotB, connector.SlotA, false)
	if err := e.runHooks(HookPreInstall, env); err != nil {
		t.Fatalf("hook did not see expected env: %v", err)
	}
}
