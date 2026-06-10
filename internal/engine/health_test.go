package engine

import (
	"errors"
	"os"
	"path/filepath"
	"testing"
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

func TestHealthChecksAbsentDirPasses(t *testing.T) {
	e := &Engine{HealthDir: filepath.Join(t.TempDir(), "nope")}
	if err := e.runHealthChecks(); err != nil {
		t.Fatalf("absent dir must pass: %v", err)
	}
}

func TestHealthChecksEmptyDirPasses(t *testing.T) {
	e := &Engine{HealthDir: t.TempDir()}
	if err := e.runHealthChecks(); err != nil {
		t.Fatalf("empty dir must pass: %v", err)
	}
}

func TestHealthChecksAllPass(t *testing.T) {
	dir := t.TempDir()
	writeHook(t, dir, "10-ok", "exit 0")
	writeHook(t, dir, "20-also-ok", "true")
	e := &Engine{HealthDir: dir}
	if err := e.runHealthChecks(); err != nil {
		t.Fatalf("all-passing hooks: %v", err)
	}
}

func TestHealthChecksFailureNamesHook(t *testing.T) {
	dir := t.TempDir()
	writeHook(t, dir, "10-ok", "exit 0")
	writeHook(t, dir, "20-bad", "exit 1")
	e := &Engine{HealthDir: dir}
	err := e.runHealthChecks()
	var hc *HealthCheckError
	if !errors.As(err, &hc) {
		t.Fatalf("want HealthCheckError, got %v", err)
	}
	if hc.Hook != "20-bad" {
		t.Fatalf("wrong hook named: %q", hc.Hook)
	}
}

func TestHealthChecksSkipsNonExecutable(t *testing.T) {
	dir := t.TempDir()
	// a non-executable file that would fail if run — must be skipped
	if err := os.WriteFile(filepath.Join(dir, "README"), []byte("not a hook\nexit 1\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	e := &Engine{HealthDir: dir}
	if err := e.runHealthChecks(); err != nil {
		t.Fatalf("non-executable files must be skipped: %v", err)
	}
}

func TestHealthChecksLexicalOrderStopsAtFirstFailure(t *testing.T) {
	dir := t.TempDir()
	marker := filepath.Join(t.TempDir(), "ran")
	writeHook(t, dir, "10-fail", "exit 3")
	writeHook(t, dir, "20-touch", "touch "+marker) // must NOT run
	e := &Engine{HealthDir: dir}
	if err := e.runHealthChecks(); err == nil {
		t.Fatal("expected failure")
	}
	if _, err := os.Stat(marker); !os.IsNotExist(err) {
		t.Fatal("later hook ran despite earlier failure")
	}
}
