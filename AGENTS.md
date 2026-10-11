# AGENTS.md

<!-- agent-skills:start -->
## Agent skills

Before starting work, read the skills below that apply to the task; each SKILL.md says when to use it. They are Sam's working playbooks and Lauren Tan's pstack (`pstack-*`), chosen for this repo. Obvious Autobuild loads them from `.obvious/skills/` on the default branch.

- [`pstack-architect`](.obvious/skills/pstack-architect/SKILL.md): Sketch types, signatures, and module structure before code, then stay in the loop while implementation fills in
- [`pstack-benchmark-checklist`](.obvious/skills/pstack-benchmark-checklist/SKILL.md): Vet a perf measurement (limiter, tuning, limits, errors, repeatability, relevance, and whether the work happened) before you report or act on it
- [`pstack-principle-boundary-discipline`](.obvious/skills/pstack-principle-boundary-discipline/SKILL.md): Apply when wiring validation, error handling, or framework adapters
- [`pstack-principle-experience-first`](.obvious/skills/pstack-principle-experience-first/SKILL.md): Apply when product, UX, or feature-scope tradeoffs come up
- [`pstack-principle-make-operations-idempotent`](.obvious/skills/pstack-principle-make-operations-idempotent/SKILL.md): Apply when designing commands, lifecycle steps, or processing loops that run amid crashes, restarts, and retries
- [`pstack-principle-model-the-domain`](.obvious/skills/pstack-principle-model-the-domain/SKILL.md): Apply when writing stateful logic, or when code branches a lot or repeats a shape assumption across files
- [`pstack-principle-prove-it-works`](.obvious/skills/pstack-principle-prove-it-works/SKILL.md): Apply after completing a task, before declaring done
- [`pstack-principle-test-behavior-not-implementation`](.obvious/skills/pstack-principle-test-behavior-not-implementation/SKILL.md): Apply when you write, change, or keep a test
- [`pstack-principle-type-system-discipline`](.obvious/skills/pstack-principle-type-system-discipline/SKILL.md): Apply when designing types, reviewing a function signature, or writing code in any statically-typed language
- [`pstack-technical-writing`](.obvious/skills/pstack-technical-writing/SKILL.md): Layered technical-writing standard: Diátaxis structure, Google developer style sentences, STE instruction rules, Global English syntax
- [`pstack-typescript-best-practices`](.obvious/skills/pstack-typescript-best-practices/SKILL.md): TypeScript best practices
- [`pstack-arena`](.obvious/skills/pstack-arena/SKILL.md): Spawn N parallel candidates at the same task, pick a base, graft the strongest parts of the losers into it *(needed by `pstack/architect`)*
- [`pstack-principle-explain-the-number`](.obvious/skills/pstack-principle-explain-the-number/SKILL.md): Apply before you trust, report, or act on a number you measured: a speedup, a regression, a throughput, a latency, or an eval result *(needed by `pstack/benchmark-checklist`)*
<!-- agent-skills:end -->
