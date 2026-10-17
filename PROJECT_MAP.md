# PROJECT_MAP

Working memory for this plugin. Kept current as work lands.

## [TECH_STACK]

| Layer | Technology | Notes |
|---|---|---|
| Shell | Quickshell 0.3.1 (Qt 6 / QML) | Omarchy Quattro; plugin loaded by manifest |
| Frontend | QML + plain ES5 JavaScript | `Model.js` is dependency-free and Node-`require`able |
| LocalSend engine | Rust (`bin/omarchy-nearby-helper`) | **byte-identical to upstream** — do not modify `backend/` |
| Tests | Node built-in `assert` + a `vm` sandbox; bash harnesses | no framework, no package.json |
| CI | GitHub Actions | Node suites + `cargo fmt/check/test` ×3 |

Verification gates (all must pass):

```sh
bash tests/all.sh   # model, service-state, panel-state, qml lint, updater, plugin validate
cargo fmt --manifest-path backend/Cargo.toml --all -- --check
```

## [SYSTEM_FLOW]

One protocol, LocalSend, behind one bar widget. (The Quick Share pane this fork
once carried is removed; `tests/qml.test.sh` keeps it from coming back.)

```
Bar (one Panel.qml PER MONITOR — view only, owns nothing singular)
  │  reads state, calls methods — engine from `bar.shell.serviceFor()`, else Bridge.qml
  ▼
Service.qml  (one per shell session — owns all engine state and the IPC target,
  │           and publishes itself to Bridge.qml for the bars the shell locks out)
  └── LocalSend ── JSON over stdin/stdout ──► bin/omarchy-nearby-helper (Rust)
                    alias supplied via Process.environment HOSTNAME (read at startup only)
```

User journeys:

1. **Discover + receive (LocalSend)** — receiver runs while enabled; popup open adds
   active discovery; inbound request → accept/decline → progress → done.
2. **Send** — pick device → pick files → progress → done.
3. **Name this machine** — cog in the hero → hostname / generated / custom.
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
- Cursor indices in the nearby view run negative: `-2` name cog, `-1` receiver
  toggle, then `0..n` rows. `moveCursor`'s clamp, `activateCursor`'s branch, and each
  row's own `hasCursor` must be changed together.
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
- **The view reaches the engine through either door.** `bar.shell.serviceFor()` answers
  only under Omarchy's own bar: `Bar.qml`'s service-capable façade is reserved for the bar
  the shell ships, and a replacement bar's widgets are handed `pluginShellForBarEntry`,
  which has no `_serviceLookup` at all — so that lookup is null *by construction* for the
  life of the session, not late. `Bridge.qml` is the plugin's own door: a QML singleton
  both halves import (one instance per engine), which the service publishes itself into
  on completion and clears on destruction, guarded so a rebuild cannot clear the newer
  instance. `Panel.qml` prefers the shell lookup and falls back to it.
  `tests/qml.test.sh` fails if either end goes missing.
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
- Plan 007's remaining gap (`Model.modeIn` / `Model.quickShareIconFor` untested) closed
  with the Quick Share removal: both functions are gone.
- Plan 008 is PARTIAL: `textFormat` on four bare `Text` elements in `Panel.qml` and the
  PIN length cap remain.
- Plans 001–006, 009–020 remain TODO.
