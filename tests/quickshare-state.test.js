const assert = require("node:assert/strict")
const fs = require("node:fs")
const vm = require("node:vm")

// QuickShare.qml is a second protocol engine: it drives an external CLI as a
// subprocess and recovers two values the user cannot do without from that
// binary's human-readable stderr -- the confirmation PIN they must match on
// their phone, and the transfer progress -- then maps the process's exit codes
// to user-facing verdicts. Both are pinned to a third party's presentation
// layer, and neither had any direct coverage: panel-state and service-state
// stub the engine as a call logger, which says nothing about what it does.
//
// Fixtures here were taken against the pinned `qs` revision a63bc7b3 (see
// QS_REV in scripts/dependencies.sh, plan 009). When that pin moves, re-check
// this file against the new binary's real output before shipping -- that is
// what the revision in this header is for.
//
// This file characterises current behaviour. Several cases below assert
// something arguably wrong; each one says so and names the plan that addresses
// it. A characterisation without that comment reads as an endorsement, which
// would be worse than no test at all.

const source = fs.readFileSync(require.resolve("../QuickShare.qml"), "utf8")

const FUNCTIONS = ["noteSendLine", "finishSend", "noteDevices", "noteDependencies"]

function extractFunction(name) {
  const marker = `function ${name}`
  const start = source.indexOf(marker)
  assert.notEqual(start, -1, `QuickShare.qml must define ${name}`)
  const brace = source.indexOf("{", start)
  let depth = 0
  let quote = ""
  let escaped = false
  for (let index = brace; index < source.length; index++) {
    const character = source[index]
    if (quote) {
      if (escaped) escaped = false
      else if (character === "\\") escaped = true
      else if (character === quote) quote = ""
      continue
    }
    if (character === "/" && source[index + 1] === "/") {
      const end = source.indexOf("\n", index)
      if (end === -1) break
      index = end
      continue
    }
    if (character === "/" && source[index + 1] === "*") {
      const end = source.indexOf("*/", index + 2)
      assert.notEqual(end, -1, `${name}: unterminated block comment`)
      index = end + 1
      continue
    }
    if (character === '"' || character === "'" || character === "`") {
      quote = character
      continue
    }
    if (character === "{") depth++
    else if (character === "}") {
      depth--
      if (depth === 0) return source.slice(start, index + 1)
    }
  }
  assert.fail(`${name}: unbalanced braces`)
}

function makeContext(initial = {}) {
  const context = {
    devices: [],
    selectedDevice: null,
    viewState: "nearby",
    statusText: "",
    errorText: "",
    progress: 0,
    transferName: "",
    transferPeer: "Pixel",
    transferPin: "",
    pendingPaths: [],
    available: false,
    depsChecked: false,
    missingDeps: [],
    cursorRequested: () => {},
    ...initial,
  }
  vm.createContext(context)
  vm.runInContext(FUNCTIONS.map(extractFunction).join("\n"), context)
  return context
}

// ---------------------------------------------------------------- noteSendLine
{
  // The PIN is the whole point of the confirmation step: the phone shows one
  // and the user has to match it. If this regex stops matching, the panel sits
  // on "Connecting…" while the phone waits for a code nobody can see.
  const state = makeContext({ transferPeer: "Pixel" })
  state.noteSendLine("Waiting for Pixel to accept…  (PIN 1234)")
  assert.equal(state.transferPin, "1234", "the PIN line must be recovered")
  assert.match(state.statusText, /Waiting for Pixel/)

  // Characterised, not endorsed: a second PIN line silently replaces the first.
  // A re-print mid-transfer would swap the code the user is reading.
  const twice = makeContext()
  twice.noteSendLine("Waiting for Pixel to accept…  (PIN 1234)")
  twice.noteSendLine("Waiting for Pixel to accept…  (PIN 5678)")
  assert.equal(twice.transferPin, "5678", "the later PIN line wins today")

  // Progress arrives as a bare percentage on its own line, at 10% granularity.
  const progress = makeContext()
  progress.noteSendLine("10%")
  assert.equal(progress.progress, 0.1)
  assert.equal(progress.statusText, "Sending")
  progress.noteSendLine("100%")
  assert.equal(progress.progress, 1)

  const padded = makeContext()
  padded.noteSendLine("  50%  ")
  assert.equal(padded.progress, 0.5, "surrounding whitespace is tolerated")

  // Characterised: the regex is anchored to a bare percentage, so a percentage
  // embedded in prose is not recognised at all.
  const prose = makeContext({ progress: 0.3 })
  prose.noteSendLine("Sending 50% of 3 files")
  assert.equal(prose.progress, 0.3, "an embedded percentage is not read")

  const clamped = makeContext()
  clamped.noteSendLine("999%")
  assert.equal(clamped.progress, 1, "progress is clamped to 1")

  const done = makeContext()
  done.noteSendLine("✓ Sent 3 file(s) to Pixel")
  assert.equal(done.progress, 1)

  // Characterised false positive: any line carrying both words counts as
  // completion, so a filename containing "Sent" and "file" would finish the bar
  // early. Named here so it cannot be mistaken for intended behaviour.
  const falsePositive = makeContext()
  falsePositive.noteSendLine("Sent-invoice-file.pdf")
  assert.equal(falsePositive.progress, 1, "…and that is a false positive")

  for (const quiet of ["", null, "Connecting to the device…"]) {
    const untouched = makeContext({ progress: 0.4, transferPin: "1234" })
    untouched.noteSendLine(quiet)
    assert.equal(untouched.progress, 0.4, `no progress change for ${JSON.stringify(quiet)}`)
    assert.equal(untouched.transferPin, "1234", `no PIN change for ${JSON.stringify(quiet)}`)
  }
}

// ------------------------------------------------------------------- finishSend
{
  const sent = makeContext({ pendingPaths: ["/tmp/a"], transferPin: "1234" })
  sent.finishSend(0)
  assert.equal(sent.viewState, "success")
  assert.equal(sent.statusText, "Sent")
  assert.equal(sent.progress, 1)
  assert.equal(sent.pendingPaths.length, 0, "a finished send stops holding paths")
  assert.equal(sent.transferPin, "", "a finished send stops showing a PIN")

  const declined = makeContext({ transferPeer: "Pixel" })
  declined.finishSend(2)
  assert.equal(declined.viewState, "error")
  assert.match(declined.errorText, /Pixel/, "the declined message names the peer")

  // 130 is a *shell* convention for 128+SIGINT. Whether the process reports it
  // that way through QProcess is exactly what plan 013 asks; this test will
  // need updating when it answers.
  const cancelled = makeContext({ selectedDevice: {alias: "Pixel"}, pendingPaths: ["/tmp/a"] })
  cancelled.finishSend(130)
  assert.equal(cancelled.viewState, "nearby")
  assert.equal(cancelled.statusText, "Cancelled")
  assert.equal(cancelled.selectedDevice, null, "a cancelled send drops the target")
  assert.equal(cancelled.pendingPaths.length, 0)

  for (const code of [1, 127]) {
    const failed = makeContext({ transferPeer: "Pixel" })
    failed.finishSend(code)
    assert.equal(failed.viewState, "error", `exit ${code} is an error`)
    assert.match(failed.errorText, /could not send/)
    assert.equal(failed.transferPin, "")
  }
}

// ------------------------------------------------------------------ noteDevices
{
  const two = makeContext()
  two.noteDevices(JSON.stringify([
    {name: "Zeta", id: "10.0.0.9:53318", ip: "10.0.0.9", port: 53318, type: "phone"},
    {name: "Alpha", id: "10.0.0.2:53318", ip: "10.0.0.2", port: 53318, type: "tablet"},
  ]))
  assert.equal(Array.from(two.devices, d => d.alias).join(","), "Alpha,Zeta", "devices sort by alias")
  assert.equal(two.devices[0].id, "10.0.0.2:53318", "the id is what --to takes, untouched")
  assert.equal(two.devices[0].deviceType, "tablet")

  const notJson = makeContext({ devices: [{alias: "stale"}] })
  notJson.noteDevices("no devices found")
  assert.equal(notJson.devices.length, 0, "unparseable output clears the list rather than throwing")

  const empty = makeContext({ devices: [{alias: "stale"}] })
  empty.noteDevices("[]")
  assert.equal(empty.devices.length, 0)

  for (const payload of [null, ""]) {
    const quiet = makeContext({ devices: [{alias: "stale"}] })
    quiet.noteDevices(payload)
    assert.equal(quiet.devices.length, 0, `no throw for ${JSON.stringify(payload)}`)
  }

  const unnamed = makeContext()
  unnamed.noteDevices(JSON.stringify([{id: "10.0.0.3:1", type: "phone"}]))
  assert.equal(unnamed.devices[0].alias, "Unknown", "a nameless device gets a placeholder")

  // Characterised, not endorsed: a device with no id is kept and is selectable,
  // and choosing it feeds an empty --to argument to the CLI.
  const idless = makeContext()
  idless.noteDevices(JSON.stringify([{name: "Ghost", id: "", type: "phone"}]))
  assert.equal(idless.devices.length, 1, "an id-less device is kept today")
  assert.equal(idless.devices[0].id, "", "…with an empty id, which --to cannot use")

  // Plan 008 (sanitise remote device names) has not landed, so a name carrying
  // markup is stored as it arrived. When it lands, this assertion changes.
  const markup = makeContext()
  markup.noteDevices(JSON.stringify([{name: "<b>Bold</b>", id: "10.0.0.4:1", type: "phone"}]))
  assert.equal(markup.devices[0].alias, "<b>Bold</b>", "markup is stored verbatim today")
}

// ------------------------------------------------------------- noteDependencies
{
  const healthy = makeContext()
  healthy.noteDependencies(JSON.stringify({
    deps: [{id: "cargo", present: true}, {id: "qs", present: true}],
  }))
  assert.equal(healthy.available, true)
  assert.equal(healthy.depsChecked, true)
  assert.equal(healthy.missingDeps.length, 0)

  const missing = makeContext({ viewState: "nearby" })
  missing.noteDependencies(JSON.stringify({
    deps: [{id: "cargo", present: true}, {id: "qs", present: false}],
  }))
  assert.equal(missing.available, false)
  assert.equal(Array.from(missing.missingDeps).join(","), "qs")
  assert.match(missing.statusText, /not installed/)

  // Characterised: a probe that fails to parse marks the check as done but
  // leaves the previous verdict, so "the probe broke" and "nothing is missing"
  // look identical. Plan 011 fixes it.
  const unparseable = makeContext({ missingDeps: ["qs"], available: false })
  unparseable.noteDependencies("not json")
  assert.equal(unparseable.depsChecked, true)
  assert.equal(Array.from(unparseable.missingDeps).join(","), "qs", "a failed probe keeps the old verdict")
}

console.log("quickshare state tests passed")
