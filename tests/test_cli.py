"""CLI surface tests: the one entry point exists and is honest about progress."""

from typer.testing import CliRunner

from lab.cli import NOT_IMPLEMENTED_EXIT_CODE, app

runner = CliRunner()


def test_help_lists_full_command_surface() -> None:
    result = runner.invoke(app, ["--help"])
    assert result.exit_code == 0
    for command in ("status", "up", "provision", "ssh", "rdp", "vm", "policy", "web"):
        assert command in result.output


def test_unimplemented_command_names_its_phase() -> None:
    result = runner.invoke(app, ["web"])
    assert result.exit_code == NOT_IMPLEMENTED_EXIT_CODE
    assert "phase 4" in result.output


def test_vm_subcommands_registered() -> None:
    result = runner.invoke(app, ["vm", "--help"])
    assert result.exit_code == 0
    for command in ("apply", "list", "start", "stop", "delete", "console", "set-password"):
        assert command in result.output
