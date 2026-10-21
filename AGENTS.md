
<!-- Local change kept: `bash tests/all.sh` replaces the individual
`node tests/model.test.js`, `node tests/panel-state.test.js` and
`node tests/service-state.test.js` invocations that upstream still lists. -->

Regression tests must exercise the reported failure and should fail against the
pre-fix behavior for the expected reason. Do not claim that Omarchy, Quickshell,
portals, peer discovery, or real-device transfers were tested when they were not.
Those runtime paths require explicit manual smoke testing on Omarchy and, for
interoperability, a real LocalSend peer.

Before handing off, inspect the final diff for unintended files and whitespace
errors. Report what changed, which checks actually ran and their results, and
any unverified runtime behavior or blockers. Do not present skipped checks as
passing.

## Reviews and releases

- Flag correctness bugs, security regressions, unnecessary dependencies, and
  unrelated scope growth. Do not request style-only refactors without a concrete
  maintenance or correctness benefit.
- Preserve contributor authorship and keep release preparation separate from a
  contributor's functional commits.
- Merge stacked pull requests in dependency order. After each merge, update the
  next branch against the current `main`, prefer rebasing when it is safe, and
  re-review the effective diff before merging it.
- Do not merge `main` into a contributor branch merely to refresh a stacked
  pull request's merge base. Avoid synchronization commits unless a concrete
  technical reason makes one necessary, and preserve contributor authorship
  when updating or rebasing the branch.
- Do not rewrite published `main` solely to make its history look cleaner.
- Stable plugin releases require matching `manifest.json`, changelog heading
  and `vX.Y.Z` tag. The helper package follows its own `helper-vX.Y.Z` cycle;
  its Cargo files, committed release metadata and published artifact must agree.
  Publish the helper first, independently verify its size, SHA256, attestation
  and version, then commit those exact values in `helper-release.env`. A plugin
  release must verify that reference and must not rebuild or republish the ELF.
- Runtime source changes after a stable release must advance the manifest to
  the next `-dev` version. Changes to helper behavior must also advance the
  helper package version and `minHelperVersion`; publish that helper first,
  then commit its exact release metadata. Repository-only documentation or CI
  changes that cannot alter the installed plugin do not require a version bump.
- Never create or move a release tag until the exact target commit has passed
  CI — the full run on `main`; a pull request's run covers only what its diff
  touches. Release helpers must come from the tagged GitHub Actions workflow, not a
  locally built binary. Helper releases stay prereleases so they cannot replace
  the latest stable plugin release in GitHub's default release view.
