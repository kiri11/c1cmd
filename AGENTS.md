# AGENTS.md

For agents developing c1. Read [AGENT_GUIDE.md](AGENT_GUIDE.md) before any
Capture One call, including live tests: it holds safety invariants 1–8, which
apply here too.

## Development invariants

9. **Tests use owned disposable fixtures, real timeouts and sequential execution,
   and keep their evidence.** Never qualify against a main Catalog or shorten a
   timeout, and keep failed-run evidence until recovery is complete.
10. **Fault cases are mandatory for mutation and recovery changes; the full
    campaign is mandatory for a new build.** Changes to mutation dispatch,
    journaling, write blocking, locks, timeouts, application lifetime,
    restart/reconciliation or stale references need the affected live fault cases.
    A new Capture One build needs every suite and fault case.

## Validating and releasing

A push to `main` publishes a release, and live checks cannot run in GitHub CI. Run
the checks the [maintainer guide](docs/MAINTAINING.md) requires locally before
pushing.

## Documentation layout

| File | Audience | In the release archive |
|---|---|---|
| `README.md` | Humans: install, MCP setup, what c1 includes and supports | Yes |
| `AGENT_GUIDE.md` | Agents using c1: setup, safety invariants 1–8, workflow | Yes |
| `docs/reference/` | Agents and operators: command detail | Yes |
| `AGENTS.md`, `docs/MAINTAINING.md`, `docs/agents/` | Developers and maintainers | No |

`scripts/package-release.sh` decides what ships. Shipped docs link only to other
shipped files; the archive test enforces this.

## Agent skills

### Issue tracker

Issues live in GitHub Issues on kiri11/c1cmd, managed with the `gh` CLI. See `docs/agents/issue-tracker.md`.

### Triage labels

Default five-role vocabulary: needs-triage, needs-info, ready-for-agent, ready-for-human, wontfix. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: one root `CONTEXT.md` plus `docs/adr/`, created lazily. See `docs/agents/domain.md`.
