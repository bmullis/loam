---
status: todo
type: HITL
created: 2026-04-26
parent_prd: docs/prds/0003-singleton-on-zenoh.md
blocked_by:
  - docs/tasks/0006-partition-lww-eviction.md
  - docs/tasks/0007-peer-death-failover.md
---

## What to build

One-time real-network validation across two physical machines (Mac + Raspberry Pi), following the convention established by `docs/journal/2026-04-25-mac-pi-real-hardware-run.md` and `docs/journal/2026-04-26-registry-mac-pi-real-hardware-run.md`. Run the happy-path, partition-claim, and peer-death tests against the Mac↔Pi pair; observe and journal anything that diverges from the localhost two-BEAM behavior.

This is HITL because it requires physical hardware setup, network manipulation (pulling cables / cycling Wi-Fi for partition tests, killing Pi power for catastrophic peer-death), and on-the-fly observation of what real-network behavior tells us that loopback didn't.

See parent PRD §User Story 26.

## Acceptance criteria

- [ ] Happy-path two-BEAM test passes against Mac↔Pi.
- [ ] Partition-claim test passes (or characterized failure modes are journaled).
- [ ] Peer-death test passes (Pi power-cycle, then OS-kill on a fresh run).
- [ ] Journal entry written with: setup notes, observations, any timing or behavior that differed from localhost, any followups discovered.
- [ ] If new failure modes are discovered, they are filed as new task slices or PRD followups, not silently fixed.

## User stories addressed

- User story 26
