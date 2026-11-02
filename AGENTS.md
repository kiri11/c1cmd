# AGENTS.md

For agents developing c1. The skills in `skills/` are for agents using it.

## Safety rules the code enforces

Keep each one enforced in code, with a test against the fake Capture One:

1. **Originals are never touched.** No command deletes images or writes files outside c1's own output.
2. **No command deletes a variant.** There are no clones.
3. **Every write is logged, and the first write to a variant snapshots it.** `revert` restores the snapshot.
4. **Warnings never block.** `doctor`, `set` and `action` warn about an untested Capture One build or an old Catalog
   backup.
5. **Mask pixels are never destroyed on a layer c1 did not create.** c1 tags its layers ` [c1:<token>]`, and
   `layer.delete` and the pixel-destructive mask actions refuse untagged layers, with no override.

## Live checks

Live checks drive the photographer's running Capture One, so:

6. **Use owned disposable documents only.** `scripts/fixture.py` creates one under `.build`, with `C1_HOME` and
   `C1_CACHES` pointing there. Never run a check against a photographer's Catalog or Session.
7. **One document, one call at a time, real timeouts.** Start with no document open, make Capture One calls
   sequentially, and never shorten a timeout.
8. **Never quit Capture One, and keep failed-run evidence.** A failed check leaves its folder under `.build`; keep
   it until the failure is understood.

## Validating and releasing

A push to `main` publishes a release, and live checks cannot run in GitHub CI. Run the checks the
[maintainer guide](docs/MAINTAINING.md) requires locally before pushing.

## Documentation layout

| File | Audience | In the plugin zip |
|---|---|---|
| `README.md` | Humans: install, first run, working with the agent | No |
| `skills/*/SKILL.md` | Agents using c1 | Yes |
| `docs/reference/commands.md` | Generated command reference; `c1 <command> --help` prints the same facts | No |
| `AGENTS.md`, `docs/MAINTAINING.md`, `docs/agents/` | Developers and maintainers | No |

`scripts/package-plugin.sh` decides what ships.

## Agent skills

### Issue tracker

Issues live in GitHub Issues on kiri11/c1cmd, managed with the `gh` CLI. See `docs/agents/issue-tracker.md`.

### Triage labels

Default five-role vocabulary: needs-triage, needs-info, ready-for-agent, ready-for-human, wontfix. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: one root `CONTEXT.md` plus `docs/adr/`, created lazily. See `docs/agents/domain.md`.
