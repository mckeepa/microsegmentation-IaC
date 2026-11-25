"""Audit-runner tests: every command is logged; failures carry real detail."""

import json
from pathlib import Path

import pytest

from lab.run import LOG_FILE_NAME, CommandError, run


@pytest.fixture
def log_file(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Path:
    monkeypatch.setenv("LAB_STATE_DIR", str(tmp_path))
    return tmp_path / "logs" / LOG_FILE_NAME


def read_entries(log_file: Path) -> list[dict[str, object]]:
    return [json.loads(line) for line in log_file.read_text().splitlines()]


def test_success_is_logged_with_outcome_and_duration(log_file: Path) -> None:
    result = run(["echo", "hello"], description="greet")
    assert result.stdout.strip() == "hello"
    (entry,) = read_entries(log_file)
    assert entry["desc"] == "greet"
    assert entry["cmd"] == ["echo", "hello"]
    assert entry["outcome"] == "exit 0"
    assert isinstance(entry["duration_s"], int | float)


def test_failure_is_logged_and_raises_with_stderr_detail(log_file: Path) -> None:
    with pytest.raises(CommandError, match="exit 2"):
        run(["ls", "/definitely-not-here-xyz"], description="list missing path")
    (entry,) = read_entries(log_file)
    assert entry["outcome"] == "exit 2"


def test_check_false_logs_but_does_not_raise(log_file: Path) -> None:
    result = run(["false"], description="probe", check=False)
    assert result.returncode == 1
    (entry,) = read_entries(log_file)
    assert entry["outcome"] == "exit 1"


def test_redacted_values_never_reach_the_log(log_file: Path) -> None:
    run(["echo", "s3cret"], description="use secret", redact=["s3cret"])
    (entry,) = read_entries(log_file)
    assert entry["cmd"] == ["echo", "***"]
    assert "s3cret" not in log_file.read_text()


def test_missing_command_is_logged_and_raises(log_file: Path) -> None:
    with pytest.raises(CommandError, match="command not found"):
        run(["no-such-binary-xyz"], description="run missing binary")
    (entry,) = read_entries(log_file)
    assert entry["outcome"] == "error: command not found"
