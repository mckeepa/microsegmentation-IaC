"""Load and validate lab.yaml, and resolve the gitignored state/ paths."""

import os
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import yaml

REPO_ROOT = Path(__file__).resolve().parents[2]
LAB_YAML = REPO_ROOT / "lab.yaml"


class ConfigError(Exception):
    """lab.yaml is missing, malformed, or fails validation."""


def state_dir() -> Path:
    return Path(os.environ.get("LAB_STATE_DIR", REPO_ROOT / "state"))


def secrets_dir() -> Path:
    path = state_dir() / "secrets"
    path.mkdir(parents=True, exist_ok=True)
    path.chmod(0o700)
    return path


def cache_dir() -> Path:
    path = state_dir() / "cache"
    path.mkdir(parents=True, exist_ok=True)
    return path


def logs_dir() -> Path:
    path = state_dir() / "logs"
    path.mkdir(parents=True, exist_ok=True)
    return path


@dataclass(frozen=True)
class Size:
    vcpus: int
    memory_gib: int
    disk_gib: int


@dataclass(frozen=True)
class OuterVM:
    name: str
    os: str
    vcpus: int
    memory_gib: int
    disk_gib: int
    network: str
    user: str

    @property
    def managed_title(self) -> str:
        """Ownership marker stored as the libvirt domain title (FR-1.5)."""
        return f"microsegmentation-iac-v2-{self.name}"


@dataclass(frozen=True)
class VMDef:
    name: str
    blueprint: str
    size: Size
    segment: str
    ports: tuple[int, ...]
    run: bool


@dataclass(frozen=True)
class LabConfig:
    outer_vm: OuterVM
    vms: tuple[VMDef, ...]


def _require(mapping: dict[str, Any], key: str, context: str) -> Any:
    if key not in mapping:
        raise ConfigError(f"{context}: missing required key '{key}'")
    return mapping[key]


def _positive_int(value: Any, key: str, context: str) -> int:
    if not isinstance(value, int) or isinstance(value, bool) or value <= 0:
        raise ConfigError(f"{context}: '{key}' must be a positive integer, got {value!r}")
    return value


def load_config(path: Path = LAB_YAML) -> LabConfig:
    if not path.is_file():
        raise ConfigError(f"lab definition not found: {path}")
    raw = yaml.safe_load(path.read_text())
    if not isinstance(raw, dict):
        raise ConfigError(f"{path}: top level must be a mapping")

    outer_raw = _require(raw, "outer_vm", str(path))
    if not isinstance(outer_raw, dict):
        raise ConfigError("outer_vm: must be a mapping")
    outer = OuterVM(
        name=str(_require(outer_raw, "name", "outer_vm")),
        os=str(outer_raw.get("os", "ubuntu-24.04")),
        vcpus=_positive_int(_require(outer_raw, "vcpus", "outer_vm"), "vcpus", "outer_vm"),
        memory_gib=_positive_int(
            _require(outer_raw, "memory_gib", "outer_vm"), "memory_gib", "outer_vm"
        ),
        disk_gib=_positive_int(_require(outer_raw, "disk_gib", "outer_vm"), "disk_gib", "outer_vm"),
        network=str(outer_raw.get("network", "default")),
        user=str(outer_raw.get("user", "labadmin")),
    )

    vms: list[VMDef] = []
    for entry in raw.get("vms") or []:
        if not isinstance(entry, dict):
            raise ConfigError("vms: each entry must be a mapping")
        name = str(_require(entry, "name", "vms"))
        context = f"vms[{name}]"
        size_raw = _require(entry, "size", context)
        size = Size(
            vcpus=_positive_int(_require(size_raw, "vcpus", context), "vcpus", context),
            memory_gib=_positive_int(
                _require(size_raw, "memory_gib", context), "memory_gib", context
            ),
            disk_gib=_positive_int(_require(size_raw, "disk_gib", context), "disk_gib", context),
        )
        vms.append(
            VMDef(
                name=name,
                blueprint=str(_require(entry, "blueprint", context)),
                size=size,
                segment=str(_require(entry, "segment", context)),
                ports=tuple(int(p) for p in entry.get("ports", [])),
                run=bool(entry.get("run", False)),
            )
        )

    names = [vm.name for vm in vms] + [outer.name]
    duplicates = {n for n in names if names.count(n) > 1}
    if duplicates:
        raise ConfigError(f"duplicate VM names: {sorted(duplicates)}")

    return LabConfig(outer_vm=outer, vms=tuple(vms))
