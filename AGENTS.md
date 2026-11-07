# AGENTS.md

Install scripts and system glue for a small personal fleet. Public repo:
never commit secrets or work-network details (NetworkManager connections,
rclone.conf, keys, VPN domains).

## Commits

- Conventional Commits, no scope: `feat: ...`, `fix: ...`, `docs: ...`, `chore: ...`
- Trailer: `Assisted-by: <agent> <model> <version>`, e.g. `Assisted-by: Claude Opus 5.5`.
  No Co-Authored-By, no session links.
- Author: the repo owner, with the GitHub noreply address.
- In manual mode, show the commit message for approval before committing.
