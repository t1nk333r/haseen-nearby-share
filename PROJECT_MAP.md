# PROJECT_MAP

Working memory for this plugin. Kept current as work lands.

## [TECH_STACK]

| Layer | Technology | Notes |
|---|---|---|
| Shell | Quickshell 0.3.1 (Qt 6 / QML) | Omarchy Quattro; plugin loaded by manifest |
| Frontend | QML + plain ES5 JavaScript | `Model.js` is dependency-free and Node-`require`able |
| LocalSend engine | Rust (`bin/omarchy-nearby-helper`) | **byte-identical to upstream** — do not modify `backend/` |
| Quick Share engine | `bin/nearby-qs`, external CLI (GPL-3.0) | short-lived subprocesses; built from a pinned rev, not vendored |
| Tests | Node built-in `assert` + a `vm` sandbox; bash harnesses | no framework, no package.json |
| CI | GitHub Actions | Node suites + `cargo fmt/check/test` ×3 |

Verification gates (all must pass):

```sh
bash tests/all.sh   # model, service-state, panel-state, qml lint, updater, plugin validate
cargo fmt --manifest-path backend/Cargo.toml --all -- --check
```

## [SYSTEM_FLOW]

Two protocols behind one bar widget, selected by two buttons at the top of the
popup — which are drawn only while the radio probe says the Quick Share half can
actually run.

```
Bar (one Panel.qml PER MONITOR — view only, owns nothing singular)
  │  reads state, calls methods
  ▼
Service.qml  (one per shell session — owns all engine state and the IPC target)
  ├── LocalSend ── JSON over stdin/stdout ──► bin/omarchy-nearby-helper (Rust)
  │                 alias supplied via Process.environment HOSTNAME (read at startup only)
  └── QuickShare.qml ── argv ──► bin/nearby-qs devices|send  (name via `--name`)
```

User journeys:

1. **Discover + receive (LocalSend)** — receiver runs while enabled; popup open adds
   active discovery; inbound request → accept/decline → progress → done.
2. **Send (either pane)** — pick device → pick files → progress → done.
3. **Name this machine** — cog in the LocalSend hero → hostname / generated / custom.
   Changing it bounces the helper, because the alias is read only at startup.

## [ARCHITECTURE]

Invariants that govern every change:

- **`Panel.qml` is a view.** The bar builds one per monitor. Anything there can only
  be one of belongs in `Service.qml`. (A locally recomputed generated name violated
  this and shipped a visible bug — fixed in plan 022.)
- **`backend/` stays byte-identical to upstream** (`git diff 3f54d18..HEAD -- backend/`
  must be empty). This is what keeps rebases cheap; backend bugs go upstream via plan 018.
- **Remote-supplied text is neutralised at ingestion**, never at the render site — three
  render sinks belong to the packaged Omarchy UI kit (`Ui/Button.qml`,
  `Ui/PanelHero.qml`) which this repo must not edit, and they use Qt's `AutoText`.
  Choke point: `Model.displayName`.
- **Automatic paths notify; explicit paths act.** No git hook or timer may invoke a
  privileged operation (plan 013).
- Cursor indices in the LocalSend nearby view run negative: `-3` name cog,
  `-2` protocol switcher, `-1` receiver toggle, then `0..n` rows. `-2` is only a
  stop while the switcher is drawn (`qsAvailable`); when it is hidden, the walk
  steps over the gap and the Quick Share pane's own rows start at 0 either way.
  `moveCursor`'s clamp, `activateCursor`'s branch, and each row's own `hasCursor`
  must be changed together.
- **The Quick Share half gates on capability, never on a flag.** `scripts/dependencies.sh
  --json` reports a `radio` object beside the dependency list (Bluetooth present and
  powered; a Wi-Fi interface that is up, with P2P in its phy), and QuickShare.qml makes
  `available` the conjunction of the two halves. The pane prints the probe's own
  `reason` sentence, so a radio that is down never reads as "install something".
- **Settings are read from `~/.config/omarchy/shell.json` and written through
  `shell.updateEntryInline`.** `shell` is `services/PluginShellApi.qml`, the whole
  surface an installed third-party plugin gets: it has **no `shellConfig`**, and
  `shell.mutateShellConfig` is only wired up for a manifest declaring the `bar` kind
  (`shell.qml:654`), which this one does not. Reading `shell.barConfig` alone is not
  enough either — it is a copy of `shellConfig.bar`, so it carries no `plugins[]`, and
  it is populated from the packaged defaults before the user's file is parsed.
  `Model.barEntry` merges the placements in the same order `shell.qml:1078`
  `updateEntryInline()` searches them (top-level `bar.layout` object entry, else the
  `plugins[]` marker, else a drawer's `items[]`), which is what makes a write
  readable back. `tests/qml.test.sh` fails the build if either dead API returns.
- **Nothing calls into the engine from a handler that can outlive it.** A `shell.json`
  write rebuilds the plugin tree, so a `Process` or `FileView` handler can fire after
  its parent's QML metaobject is gone, where a function on the parent reads
  `undefined`. Every such handler reaches the engine through `owner`, captured at
  construction, and checks `typeof owner.fn === "function"` first — never through the
  `root` id lookup. `tests/service-state.test.js` runs every handler against a
  destroyed engine.

## [ORPHANS & PENDING]

Empty — all three plans in this build (022, 023, 024) are complete and verified.

Tracked but deliberately out of this build's scope, recorded in `plans/README.md`:

- Test-coverage gaps behind the 021 defects (untested rename-guard producer, untested
  `persistDeviceName` settings merge, no assertion on `Process.environment`, the
  `device_name` view untested). Not planned — the maintainer scoped this build to bugs
  and security.
- Plan 007 is PARTIAL: `Model.modeIn` / `Model.quickShareIconFor` are exported but have
  zero assertions.
- Plan 008 is PARTIAL: `textFormat` on four bare `Text` elements in `Panel.qml`, the PIN
  length cap, and routing `QuickShare.noteDevices` through `displayName` remain.
- Plans 001–006, 009–020 remain TODO.
