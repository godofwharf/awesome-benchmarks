# awesome-benchmarks

A collection of focused, self-contained benchmark modules for systems-level topics.
Each module lives in its own directory, ships with its own build and run scripts, and
shares a common library of OS-detection and dependency-installation helpers.

---

## Repository Structure

```
awesome-benchmarks/
├── common/                   # Shared scripts used by all benchmark modules
│   ├── detect_os.sh          # Detects OS type, name, and version
│   ├── debian_install.sh     # Installs dependencies via apt (Debian/Ubuntu)
│   ├── macos_install.sh      # Installs dependencies via Homebrew (macOS)
│   └── rhel_install.sh       # Installs dependencies via yum/dnf (RHEL/CentOS/Fedora)
│
└── memory_allocators/        # Benchmark: ptmalloc2 vs tcmalloc vs jemalloc
    ├── README.md              # Objective, workload details, and usage
    ├── mem_bench.c            # Multi-threaded C workload
    ├── setup.sh               # Installs all dependencies for this module
    └── run.sh                 # Compiles mem_bench.c and runs the full benchmark suite
```

---

## common/

Shared infrastructure used by every benchmark module. Scripts here are **never
invoked directly by the user** — each module's `setup.sh` sources or calls them.

| Script | Purpose |
|---|---|
| `detect_os.sh` | Exports `OS_TYPE` (`macos`/`debian`/`rhel`), `OS_NAME`, and `OS_VER`. Can be sourced or executed. |
| `debian_install.sh` | Installs gcc, perf, tcmalloc (gperftools), jemalloc, and hyperfine on Debian/Ubuntu via `apt-get`. Requires root. |
| `rhel_install.sh` | Same package set on RHEL/CentOS/Fedora via `dnf`/`yum`. Enables EPEL. Requires root. |
| `macos_install.sh` | Same package set on macOS via Homebrew. Does not require sudo. Notes that `perf` is Linux-only. |

---

## Benchmarks

| Module | What it measures |
|---|---|
| [`memory_allocators/`](memory_allocators/README.md) | Throughput and fragmentation of ptmalloc2, tcmalloc, and jemalloc under high-concurrency bimodal workloads |

See each module's `README.md` for objectives, workload details, and usage instructions.

---

## Adding a New Benchmark Module

1. Create a new top-level directory (e.g., `sorting_algorithms/`).
2. Add a `setup.sh` that resolves `REPO_ROOT` and sources scripts from `common/`:
   ```bash
   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
   REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
   source "${REPO_ROOT}/common/detect_os.sh"
   ```
3. Add a `run.sh` that builds and runs the benchmark.
4. Add a `README.md` inside the module directory documenting its objective, workload, and usage.
5. Add a row for the new module to the **Benchmarks** table in this file.

Do **not** modify or duplicate anything inside `common/` — extend it only if a new
shared capability is genuinely needed by multiple modules.

---

## License

MIT — see [LICENSE](LICENSE).
