"""lab.yaml loading and validation tests."""

from pathlib import Path

import pytest

from lab.config import LAB_YAML, ConfigError, load_config

MINIMAL = """\
outer_vm:
  name: outer
  vcpus: 8
  memory_gib: 32
  disk_gib: 150
vms:
  - name: web-01
    blueprint: ubuntu-server
    size: {vcpus: 2, memory_gib: 2, disk_gib: 10}
    segment: web
    ports: [22, 8080]
    run: true
"""


def write(tmp_path: Path, content: str) -> Path:
    path = tmp_path / "lab.yaml"
    path.write_text(content)
    return path


def test_loads_outer_vm_and_vms(tmp_path: Path) -> None:
    lab_config = load_config(write(tmp_path, MINIMAL))
    assert lab_config.outer_vm.name == "outer"
    assert lab_config.outer_vm.memory_gib == 32
    assert lab_config.outer_vm.user == "labadmin"  # default
    assert lab_config.outer_vm.managed_title == "microsegmentation-iac-v2-outer"
    (vm,) = lab_config.vms
    assert vm.ports == (22, 8080)
    assert vm.run is True


def test_missing_required_key_names_the_context(tmp_path: Path) -> None:
    with pytest.raises(ConfigError, match="outer_vm: missing required key 'memory_gib'"):
        load_config(write(tmp_path, "outer_vm: {name: x, vcpus: 1, disk_gib: 1}"))


def test_non_positive_size_rejected(tmp_path: Path) -> None:
    bad = MINIMAL.replace("memory_gib: 32", "memory_gib: 0")
    with pytest.raises(ConfigError, match="positive integer"):
        load_config(write(tmp_path, bad))


def test_duplicate_names_rejected(tmp_path: Path) -> None:
    duplicated = MINIMAL + MINIMAL[MINIMAL.index("  - name: web-01") :]
    with pytest.raises(ConfigError, match="duplicate VM names"):
        load_config(write(tmp_path, duplicated))


def test_repo_lab_yaml_is_valid() -> None:
    lab_config = load_config(LAB_YAML)
    assert lab_config.outer_vm.name == "lab2-20261114-k8s"
    assert lab_config.outer_vm.memory_gib == 32
    assert lab_config.outer_vm.disk_gib == 150
