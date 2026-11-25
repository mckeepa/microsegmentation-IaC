"""The audit-logged runner for ALL external commands (NFR-6).

Every virsh/virt-install/kubectl/ssh/curl/... invocation flows through
`run()`, which appends one JSON line per command to state/logs/commands.log
with timestamp, command, description, exit status, and duration. Code in this
package must never call subprocess directly (NFR-6.3). Values passed in
`redact` are masked in the log (NFR-6.2).
"""

import json
import subprocess
import time
from collections.abc import Sequence
from datetime import UTC, datetime

from lab.config import logs_dir

LOG_FILE_NAME = "commands.log"


class CommandError(Exception):
    """An external command failed (non-zero exit, missing binary, or timeout)."""

    def __init__(self, message: str, completed: subprocess.CompletedProcess[str] | None = None):
        super().__init__(message)
        self.completed = completed


def _log_entry(
    description: str, logged_command: list[str], outcome: str, duration_s: float
) -> None:
    entry = {
        "ts": datetime.now(UTC).isoformat(timespec="seconds"),
        "desc": description,
        "cmd": logged_command,
        "outcome": outcome,
        "duration_s": round(duration_s, 2),
    }
    log_file = logs_dir() / LOG_FILE_NAME
    with log_file.open("a") as handle:
        handle.write(json.dumps(entry) + "\n")


def run(
    args: Sequence[str],
    *,
    description: str,
    check: bool = True,
    capture: bool = True,
    input_text: str | None = None,
    redact: Sequence[str] = (),
    timeout: float | None = None,
) -> subprocess.CompletedProcess[str]:
    """Run one external command, always audit-logging it (NFR-6.1).

    With capture=False the command inherits the terminal (interactive SSH,
    consoles); output is then not available on the result.
    """
    logged_command = ["***" if arg in redact else arg for arg in args]
    start = time.monotonic()
    try:
        completed = subprocess.run(
            list(args),
            text=True,
            capture_output=capture,
            input=input_text,
            timeout=timeout,
        )
    except FileNotFoundError:
        _log_entry(
            description, logged_command, "error: command not found", time.monotonic() - start
        )
        raise CommandError(f"command not found: {args[0]}") from None
    except subprocess.TimeoutExpired:
        _log_entry(
            description,
            logged_command,
            f"error: timeout after {timeout}s",
            time.monotonic() - start,
        )
        raise CommandError(f"timed out after {timeout}s: {logged_command[0]}") from None
    _log_entry(
        description, logged_command, f"exit {completed.returncode}", time.monotonic() - start
    )
    if check and completed.returncode != 0:
        stderr_tail = (completed.stderr or "").strip().splitlines()[-1:] if capture else []
        detail = f": {stderr_tail[0]}" if stderr_tail else ""
        raise CommandError(
            f"{description} failed (exit {completed.returncode}){detail}", completed=completed
        )
    return completed
