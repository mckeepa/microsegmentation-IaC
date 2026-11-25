"""CLI surface tests: the one entry point exists and is honest about progress."""

from typer.testing import CliRunner

from lab.cli import NOT_IMPLEMENTED_EXIT_CODE, app

runner = CliRunner()


def test_help_lists_full_command_surface() -> None:
    result = runner.invoke(app, ["--help"])
    assert result.exit_code == 0
    for command in ("status", "up", "provision", "ssh", "rdp", "vm", "image", "policy", "web"):
        assert command in result.output


def test_help_shows_vm_and_rdp_examples() -> None:
    result = runner.invoke(app, ["--help"], color=False, terminal_width=120)
    assert result.exit_code == 0
    assert "uv run lab vm list" in result.output
    assert "uv run lab rdp desk-01" in result.output
    assert "uv run lab rdp --all" in result.output
    assert "xfreerdp3 /v:127.0.0.1:13389 /u:desktop" in result.output


def test_unimplemented_command_names_its_phase() -> None:
    result = runner.invoke(app, ["web"])
    assert result.exit_code == NOT_IMPLEMENTED_EXIT_CODE
    assert "phase 4" in result.output


def test_rdp_rejects_missing_or_conflicting_selection() -> None:
    for args in (["rdp"], ["rdp", "desk-01", "--all"]):
        result = runner.invoke(app, args)
        assert result.exit_code == 2
        assert "specify a VM name or --all" in result.output


def test_vm_subcommands_registered() -> None:
    result = runner.invoke(app, ["vm", "--help"])
    assert result.exit_code == 0
    for command in ("apply", "list", "start", "stop", "delete", "console", "set-password"):
        assert command in result.output


def test_image_fetch_rejects_unknown_blueprint() -> None:
    result = runner.invoke(app, ["image", "fetch", "no-such-blueprint"])
    assert result.exit_code == 1
    assert "unknown blueprint" in result.output
