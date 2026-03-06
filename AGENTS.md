# AGENTS

Guidelines for AI agents (Copilot, Claude, Cursor, Codex, etc.) working in this repository.

---

## CRITICAL: Do Not Change the Repository Structure

**Agents must never rename, move, delete, or reorganize any file or directory in this
repository without an explicit instruction from a human maintainer.**

This rule applies to:

- The top-level layout (`common/`, `memory_allocators/`, and any future module directories)
- The contents and names of scripts inside `common/`
- The names of files inside any benchmark module (`setup.sh`, `run.sh`, source files, etc.)
- The `README.md`, `AGENTS.md`, `LICENSE`, and `.gitignore` files

### Why this matters

Every benchmark module's `setup.sh` resolves paths relative to the repository root at
**runtime**. Renaming or moving a directory — even an apparently harmless refactor —
will silently break path resolution across all modules. There is no static build step
to catch these breaks before they reach users.

### What agents may do

- Edit the **contents** of existing files to fix bugs, improve logic, or add features.
- Add new files **inside** an existing module directory when explicitly asked.
- Create a **new top-level benchmark module directory** when explicitly asked, following
  the conventions described in `README.md`.

### What agents must never do without explicit human instruction

| Prohibited action | Example |
|---|---|
| Rename a file | `run.sh` → `benchmark.sh` |
| Move a file to a different directory | `common/detect_os.sh` → `memory_allocators/detect_os.sh` |
| Delete a file or directory | removing `common/rhel_install.sh` |
| Restructure the top-level layout | merging `common/` into each module |
| Introduce a new shared-script location | creating a `lib/` or `scripts/` directory as an alternative to `common/` |

If a task seems to require any of the above, **stop and ask the human maintainer**
before proceeding.
