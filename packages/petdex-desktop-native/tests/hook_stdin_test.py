#!/usr/bin/env python3
"""Exercise the native runner and production shell wrappers with open stdin.

The runner exits before starting the desktop UI.  Keeping the parent pipe open
therefore tests the exact failure mode that used to leave agent hook processes
waiting forever, without requiring a display, a token, or a running server.
"""

from __future__ import annotations

import json
import os
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path


MAX_EXIT_SECONDS = 3.0


def run_case(
    binary: Path,
    label: str,
    payload: bytes | None,
    command: str | None = None,
    shell: str | None = None,
    runner: str = "enabled",
    expected_stdout: bytes = b"",
) -> None:
    with tempfile.TemporaryDirectory(prefix="petdex-hook-test-") as home:
        env = os.environ.copy()
        env["HOME"] = home
        env["USERPROFILE"] = home
        env["APPDATA"] = home
        if command is not None and runner != "missing":
            launcher = Path(home) / ".petdex/bin/petdex-hook"
            if os.name == "nt":
                launcher = launcher.with_suffix(".cmd")
            launcher.parent.mkdir(parents=True)
            if runner == "failed":
                failed_runner = (
                    '@echo off\r\necho {"permissionDecision":"deny"}\r\necho failure >&2\r\nexit /b 2\r\n'
                    if os.name == "nt"
                    else '#!/bin/sh\nprintf \'%s\\n\' \'{"permissionDecision":"deny"}\'\nprintf failure >&2\nexit 2\n'
                )
                launcher.write_bytes(failed_runner.encode())
                launcher.chmod(0o700)
            elif os.name == "nt":
                # Same direct launcher contract as plat.windowsHookLauncher;
                # no symlink privileges or actual installed hooks are needed.
                launcher.write_bytes(
                    f'@echo off\r\n"{str(binary).replace("%", "%%")}" %*\r\n'.encode()
                )
            else:
                launcher.symlink_to(binary)
        if runner == "disabled":
            disabled = Path(home) / ".petdex/runtime/hooks-disabled"
            disabled.parent.mkdir(parents=True)
            disabled.touch()

        argv = [str(binary), "bubble", "post", "codex"]
        if command is not None:
            if shell == "powershell":
                argv = [
                    "powershell.exe", "-NoLogo", "-NoProfile", "-NonInteractive",
                    "-Command", command,
                ]
            elif os.name == "nt":
                # cmd's /c quoting is not CommandLineToArgvW: preserve the
                # generated command's quotes instead of Python's list escaping.
                comspec = os.environ.get("COMSPEC", "cmd.exe")
                argv = f'"{comspec}" /d /s /c "{command}"'
            else:
                argv = ["/bin/sh", "-e", "-c", command]
        child = subprocess.Popen(
            argv,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=env,
            start_new_session=os.name != "nt",
        )
        try:
            if payload is not None:
                assert child.stdin is not None
                try:
                    child.stdin.write(payload)
                    child.stdin.flush()
                except BrokenPipeError:
                    # A missing runner deliberately exits immediately. The
                    # host may observe EPIPE but cannot be left waiting forever.
                    if runner not in ("missing", "failed"):
                        raise
                # Deliberately do not close stdin.  The parent keeps the pipe
                # open to reproduce hosts that write JSON but never send EOF.

            started = time.monotonic()
            try:
                exit_code = child.wait(timeout=MAX_EXIT_SECONDS)
            except subprocess.TimeoutExpired as error:
                if os.name == "nt":
                    subprocess.run(
                        ["taskkill", "/PID", str(child.pid), "/T", "/F"],
                        stdout=subprocess.DEVNULL,
                        stderr=subprocess.DEVNULL,
                        check=False,
                    )
                else:
                    os.killpg(child.pid, signal.SIGKILL)
                child.wait()
                raise AssertionError(f"hook did not exit for {label}") from error

            elapsed = time.monotonic() - started
            if exit_code != 0:
                raise AssertionError(f"native hook exited {exit_code} for {label}")
            if elapsed > MAX_EXIT_SECONDS:
                raise AssertionError(f"native hook exceeded timeout for {label}")
            assert child.stdout is not None
            actual_stdout = child.stdout.read()
            if actual_stdout != expected_stdout:
                raise AssertionError(f"unexpected host output for {label}: {actual_stdout!r}")
            assert child.stderr is not None
            actual_stderr = child.stderr.read()
            if actual_stderr:
                raise AssertionError(f"unexpected host error for {label}: {actual_stderr!r}")
        finally:
            if child.stdin is not None:
                try:
                    child.stdin.close()
                except BrokenPipeError:
                    pass
            if child.stdout is not None:
                child.stdout.close()
            if child.stderr is not None:
                child.stderr.close()


def shell_commands(temp: Path) -> list[dict[str, str]]:
    """Compile the real formatter, so changes to installed commands are covered."""
    package = Path(__file__).resolve().parent.parent
    fixture = temp / ("hook-commands.exe" if os.name == "nt" else "hook-commands")
    subprocess.run(
        [
            os.environ.get("ZIG", "zig"),
            "build-exe",
            "-lc",
            "--dep", "hooks",
            f"-Mroot={package / 'tests/hook_commands.zig'}",
            f"-Mhooks={package / 'src/agent_hooks.zig'}",
            f"-femit-bin={fixture}",
            "--cache-dir", str(temp / "local-cache"),
            "--global-cache-dir", str(temp / "global-cache"),
        ],
        check=True,
    )
    result = subprocess.run([str(fixture)], check=True, capture_output=True, text=True)
    return [json.loads(line) for line in result.stdout.splitlines()]


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: hook_stdin_test.py <native-binary>", file=sys.stderr)
        return 2

    binary = Path(sys.argv[1])
    if not binary.is_file() and Path(f"{binary}.exe").is_file():
        binary = Path(f"{binary}.exe")
    if not binary.is_file():
        print("native hook binary is missing", file=sys.stderr)
        return 2
    binary = binary.resolve()

    run_case(binary, "complete payload without EOF", b'{"tool_name":"Read"}')
    run_case(binary, "silent stdin", None)
    with tempfile.TemporaryDirectory(prefix="petdex-hook-commands-") as temp:
        for item in shell_commands(Path(temp)):
            shell = (
                "powershell"
                if os.name == "nt" and item["agent"] in ("copilot", "windsurf")
                else None
            )
            expected = b""
            if item["agent"] == "cursor":
                expected = b"{}\r\n" if os.name == "nt" else b"{}\n"
            for runner in ("enabled", "disabled", "missing", "failed"):
                for label, payload in (
                    ("complete payload without EOF", b'{"tool_name":"Read"}'),
                    ("silent stdin", None),
                ):
                    run_case(
                        binary,
                        f"{item['agent']} shell / {runner} / {label}",
                        payload,
                        command=item["command"],
                        shell=shell,
                        runner=runner,
                        expected_stdout=expected,
                    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
