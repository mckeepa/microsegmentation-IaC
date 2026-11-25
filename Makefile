# One-command checks (NFR-2.2). Usage: make check
.PHONY: check fmt

check:
	uv run ruff format --check src tests
	uv run ruff check src tests
	uv run mypy
	uv run pytest -q

fmt:
	uv run ruff format src tests
	uv run ruff check --fix src tests
