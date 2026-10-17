# UPSTREAM — `haseen.nearby-share`

- **plugin id**: `haseen.nearby-share` (renamed from `t1nk33r.nearby-share` on 2026-10-17, with the haseen rebrand)
- **plugin version**: `1.1.3`
- **`omarchy.clonedFrom`**: absent by design — the host's disable branch rewrites the bar entry to the declared id, and `oma.nearby` is not installed here (key dropped 2026-09-11; see `plans/notes/119-clonedfrom-hazard.md`)
- **ownership**: `~/.config/omarchy/plugins/haseen.nearby-share`, an owner fork: its working files are yadm-tracked, its own git repo stays on disk — **fork repo (origin)**: `git@github.com:t1nk333r/haseen-nearby-share.git` (formerly `omarchy-nearby-share`)
- **upstream repo**: `https://github.com/jfg96/omarchy-nearby.git`
- **tracking branch**: `main` (local HEAD `24308ad9d3b0`)
- **last-synced upstream commit**: `4b695554bc8105706ec8bd2d4a988be2d3b1c4b4` — pinned by `tools/plugin-upstream-report.sh` as `refs/upstream/main` (plan 119 §3)
- **drift at the last report (plans 119–120)**: ahead 8, behind 0

## Fork / local commits (newest first, `refs/upstream/<branch>..HEAD`)

- `24308ad manifest: drop omarchy.clonedFrom (oma.nearby is not installed here)`
- `4c170d7 manifest: declare omarchy.clonedFrom (plan 119)`
- `6ee83b3 fix: read config from disk and write through updateEntryInline`
- `0f0a651 docs: add implementation plans from the improve audit`
- `4738865 feat: let the user choose the name this machine advertises`
- `0842d84 fix: make the fork's own tests and recovery path correct`
- `be4a635 fix: stop the search button repeating the status line`
- `f5a5303 docs: point the clone URL at this fork`
- `ce4f3a2 feat: add a Quick Share pane beside LocalSend`

- recovery tag(s): `backup/pre-upstream-rebase-20260911`

## Patch records

- none — no unpushed local commit needs recording for this plugin

## Restore / update notes

- Restore: a re-clone lands pristine upstream; this clone carries no local commit of its own beyond plan 119's metadata (recorded as a patch above).
- Upstream drift is measured read-only by `~/.local/share/waydots/tools/plugin-upstream-report.sh`; run it before any rebase (plan 119's `plans/notes/119-upstream-status.md` is the pinned baseline).
- Never push a third-party clone; a local rebase of one is a deployment change and belongs in `packages/plugin-patches/`.
- Written by plan 124 (2026-09-11); topology from plan 119, re-verified read-only by plan 124.
