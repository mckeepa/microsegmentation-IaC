"""Every pinned external version lives here (NFR-2.3).

Sources: requirements/30-constraints.md (v1 known-good baseline) and the
Cilium stable channel. Download checksums are added beside each artifact as
the phases that fetch them are implemented.
"""

OUTER_VM_OS = "ubuntu-24.04"  # Ubuntu Server 24.04 LTS
UBUNTU_ISO = "ubuntu-24.04.5-live-server-amd64.iso"
UBUNTU_ISO_URL = f"https://releases.ubuntu.com/24.04/{UBUNTU_ISO}"
UBUNTU_ISO_SHA256 = "97f3d7ffb032c3eb3b23d2c8be9cc76e60c2c1f2c0146ba5ba9fe01cafae0fd8"
K3S = "v1.36.5+k3s1"
CILIUM = "v1.20.4"  # stable as of 2026-11-14; L7-capable CNI (FR-4.4)
KUBEVIRT = "v1.9.1"  # also pins virtctl
CDI = "v1.66.1"
HELM = "v3.22.1"
