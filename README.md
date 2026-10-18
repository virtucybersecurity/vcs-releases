# VCS release artifacts

This repository contains release inputs for supported VCS components.
Preserve unrelated Studio, Gateway and local-auth releases when maintaining it.

## Retired standalone Container Guard — 18 October 2026

The separate Container Guard API, dashboard, installer and periodic scanner are
retired. Their `container-guard/v0.1.0`, `v0.1.1` and `v0.1.2` runtime archives
were removed from the current Git tree. Do not publish or restore those archives
from Git history, backups or an older clone.

Current Container Guard is part of VCS App (`/security/container-guard`) and its
Rust agent. It collects Docker inventory and applies the integrated policy
checks through the existing signed command channel. It requires no standalone
Container Guard service, database, cron entry or ports 3847/4000.

The integrated implementation, its supported container actions and Docker/
containerd are retained. Legacy cleanup is separate from removing the current
VCS feature. See VCS App `docs/container-guard.md` and
`docs/audits/vcs-agent-artifact-cleanup-2026-10-18.md` for the retirement record.
