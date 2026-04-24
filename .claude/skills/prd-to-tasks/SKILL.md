---
name: prd-to-tasks
description: Break a PRD into independently-grabbable task markdown files using tracer-bullet vertical slices. Use when user wants to convert a PRD to tasks, break down a PRD into work items, or turn a PRD into actionable slices.
---

# PRD to Tasks

Break a PRD into independently-grabbable task files using vertical slices (tracer bullets). Tasks live as markdown files in `docs/tasks/`.

## Process

### 1. Locate the PRD

Ask the user which PRD to break down. PRDs live in `docs/prds/NNNN-slug.md`. If the user gives a slug or partial name, use Glob to find it.

If the PRD is not already in your context window, read it.

### 2. Explore the codebase (optional)

If you have not already explored the codebase, do so to understand the current state of the code.

### 3. Draft vertical slices

Break the PRD into **tracer bullet** tasks. Each task is a thin vertical slice that cuts through ALL integration layers end-to-end, NOT a horizontal slice of one layer.

Slices may be 'HITL' or 'AFK'. HITL slices require human interaction, such as an architectural decision or a design review. AFK slices can be implemented and merged without human interaction. Prefer AFK over HITL where possible.

<vertical-slice-rules>
- Each slice delivers a narrow but COMPLETE path through every layer (schema, API, UI, tests)
- A completed slice is demoable or verifiable on its own
- Prefer many thin slices over few thick ones
</vertical-slice-rules>

### 4. Quiz the user

Present the proposed breakdown as a numbered list. For each slice, show:

- **Title**: short descriptive name
- **Type**: HITL / AFK
- **Blocked by**: which other slices (if any) must complete first
- **User stories covered**: which user stories from the PRD this addresses

Ask the user:

- Does the granularity feel right? (too coarse / too fine)
- Are the dependency relationships correct?
- Should any slices be merged or split further?
- Are the correct slices marked as HITL and AFK?

Iterate until the user approves the breakdown.

### 5. Create the task files

For each approved slice, write a markdown file at `docs/tasks/NNNN-slug.md`.

**File naming:**
- `NNNN` is a zero-padded 4-digit sequence number. Look at the highest existing number in `docs/tasks/` and increment by 1. If the directory doesn't exist, create it and start at `0001`.
- `slug` is short kebab-case (e.g. `map-topics-to-keyexprs`, `wire-in-congestion-control`).

**Frontmatter:**
```
---
status: todo
type: AFK
created: YYYY-MM-DD
parent_prd: docs/prds/NNNN-slug.md
blocked_by:
  - docs/tasks/NNNN-slug.md
---
```

- `status`: `todo | in-progress | done | abandoned`. Update the field in place when status changes — do not move files.
- `type`: `AFK` or `HITL`.
- `blocked_by`: omit the key entirely if no blockers.

Create files in dependency order (blockers first) so you can reference real file paths in the `blocked_by` field.

<task-template>
## What to build

A concise description of this vertical slice. Describe the end-to-end behavior, not layer-by-layer implementation. Reference specific sections of the parent PRD rather than duplicating content.

## Acceptance criteria

- [ ] Criterion 1
- [ ] Criterion 2
- [ ] Criterion 3

## User stories addressed

Reference by number from the parent PRD:

- User story 3
- User story 7
</task-template>

Do NOT modify the parent PRD file. After writing all task files, print the list of created paths so the user can open them.
