## Project: RentSync
Portfolio project demonstrating integration engineering in Ruby (Grape/Sequel) + Next.js/TypeScript.
Workflow: GitHub Spec Kit. Specs live in /specs; the constitution in .specify/memory/constitution.md is authoritative.
This file is runtime guidance only and MUST NOT contradict the constitution. If they disagree, the constitution wins.

## Working rules
- Follow the current feature's tasks.md in order; tick tasks off as you complete them.
- Write failing tests before domain logic (ledger, matching, idempotency, export).
- Never weaken a test to make it pass. If a test seems wrong, stop and note it in docs/ai-build-log.md.
- Run the full test suite before each commit; commit in small, well-described steps.
- No new dependencies without a justification line in plan.md.
- Never commit secrets; use .env.example.
- At the end of each session, append to docs/ai-build-log.md: what was done, what was blocked, decisions made, and the next task.
