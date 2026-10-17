const assert = require("node:assert/strict")
const Model = require("../Model.js")

const phone = {alias:"<b>Phone</b>",fingerprint:"fp",deviceType:"mobile",ip:"192.0.2.2"}
assert.equal(Model.upsertDevice([], phone).length, 1)
assert.equal(Model.upsertDevice(Model.upsertDevice([], phone), {...phone, alias:"Phone 2"})[0].alias, "Phone 2")
assert.deepEqual(Model.snapshotDevices([phone, {...phone, alias:"Newest"}]).map(d => d.alias), ["Newest"])

// The frontend device array is the Rust peer registry's mirror and must never
// exceed the same bound: LAN identity churn has to stay capped even while the
// discovery view is closed. One constant drives both event and snapshot paths.
const MAX_DEVICES = Model.MAX_DEVICES
assert.equal(typeof MAX_DEVICES, "number")
assert.ok(MAX_DEVICES > 0)

function deviceAt(fingerprint, alias) {
  return {fingerprint, alias, deviceType:"desktop", ip:"192.0.2.2"}
}

// Normal behavior with few devices is unchanged.
{
  let list = []
  for (let i = 0; i < 5; i++) list = Model.upsertDevice(list, deviceAt("fp-"+i, "Alias "+i))
  assert.equal(list.length, 5)
}

// More than MAX_DEVICES unique fingerprints never grow the array past the bound.
{
  let list = []
  const extra = 100
  for (let i = 0; i < MAX_DEVICES + extra; i++) list = Model.upsertDevice(list, deviceAt("fp-"+i, "Device-"+String(i).padStart(4, "0")))
  assert.equal(list.length, MAX_DEVICES)
}

// Updating an existing fingerprint does not increase the size at the bound.
{
  let list = []
  for (let i = 0; i < MAX_DEVICES; i++) list = Model.upsertDevice(list, deviceAt("fp-"+i, "Device-"+String(i).padStart(4, "0")))
  const before = list.length
  list = Model.upsertDevice(list, deviceAt("fp-0", "Renamed"))
  assert.equal(list.length, before)
  const renamed = list.find(device => device.fingerprint === "fp-0")
  assert.equal(renamed.alias, "Renamed")
}

// A snapshot of more than MAX_DEVICES devices returns at most MAX_DEVICES.
{
  const many = []
  for (let i = 0; i < MAX_DEVICES + 50; i++) many.push(deviceAt("snap-"+i, "Snap-"+String(i).padStart(4, "0")))
  const snapshot = Model.snapshotDevices(many)
  assert.ok(snapshot.length <= MAX_DEVICES)
}

// Deduplication by fingerprint keeps working, inside and beyond the bound.
assert.deepEqual(Model.snapshotDevices([deviceAt("x", "A")]).length, 1)
assert.deepEqual(Model.snapshotDevices([deviceAt("x", "A"), deviceAt("x", "B")]).map(device => device.alias), ["B"])
{
  let list = []
  const branded = {}
  for (let i = 0; i < MAX_DEVICES + 20; i++) {
    branded["brand-"+i] = "Branded "+i
    list = Model.upsertDevice(list, deviceAt("brand-"+i, "Branded "+i))
  }
  list = Model.upsertDevice(list, deviceAt("brand-0", "Renamed Brand"))
  assert.equal(list.length, MAX_DEVICES)
  assert.equal(list.filter(device => device.fingerprint === "brand-0").length, 1)
}

// Alias ordering stays deterministic at the bound.
{
  let list = []
  for (let i = 0; i < MAX_DEVICES + 10; i++) list = Model.upsertDevice(list, deviceAt("fp-"+i, "Device-"+String(i).padStart(4, "0")))
  for (let i = 1; i < list.length; i++) assert.ok(list[i-1].alias.localeCompare(list[i].alias) <= 0)
}

assert.equal(Model.parseLine("not json"), null)
const requestA = {requestId:"a",sender:"Alice"}
const requestB = {requestId:"b",sender:"Bob"}
const requestC = {requestId:"c",sender:"Carol"}
assert.deepEqual(Model.enqueueIncoming([], null), [])
assert.deepEqual(Model.enqueueIncoming([], {}), [])
assert.deepEqual(Model.enqueueIncoming([], requestA), [requestA])
assert.deepEqual(Model.enqueueIncoming([requestA], requestB), [requestA, requestB])
assert.deepEqual(Model.enqueueIncoming([requestA, requestB], {...requestA, sender:"Alice updated"}).map(r => r.sender), ["Alice updated", "Bob"])
assert.deepEqual(Model.removeIncoming([requestA, requestB, requestC], "b"), [requestA, requestC])
assert.deepEqual(Model.removeIncoming([requestA, requestB], "missing"), [requestA, requestB])
assert.equal(Model.currentIncoming([requestA, requestB]), requestA)
assert.equal(Model.currentIncoming([]), null)
assert.equal(Model.currentIncoming(null), null)
const pendingFiles = {kind:"files",device:phone,paths:["/tmp/a","/tmp/b"]}
const pendingText = {kind:"text",device:phone,text:"hello"}
assert.equal(Model.outgoingCommand(null, "out-1", null), null)
assert.deepEqual(Model.outgoingCommand(pendingFiles, "out-1", null), {command:"send_files",transfer_id:"out-1",device:phone,paths:["/tmp/a","/tmp/b"]})
assert.deepEqual(Model.outgoingCommand(pendingText, "out-2", "123456"), {command:"send_text",transfer_id:"out-2",device:phone,text:"hello",pin:"123456"})
assert.deepEqual(Model.outgoingCommand(pendingText, "out-3", "a+b & # % contraseña"),
  {command:"send_text",transfer_id:"out-3",device:phone,text:"hello",pin:"a+b & # % contraseña"})
assert.equal(Object.hasOwn(pendingText, "pin"), false)
assert.equal(Model.viewAfterOutgoing(true, "success"), "incoming")
assert.equal(Model.viewAfterOutgoing(false, "error"), "error")
assert.equal(Model.helperVersionMatches("1.0.0", "1.0.0"), true)
assert.equal(Model.helperVersionMatches("1.0.1-dev", "1.0.0"), false)
assert.equal(Model.helperVersionMatches("1.0.0", ""), false)
assert.equal(Model.helperVersionMatches("", ""), false)
assert.equal(Model.manifestVersion('{"id":"oma.nearby","version":"1.0.2"}', "oma.nearby"), "1.0.2")
assert.equal(Model.manifestVersion('{"id":"other.plugin","version":"1.0.2"}', "oma.nearby"), "")
assert.equal(Model.manifestVersion('{"id":"oma.nearby"}', "oma.nearby"), "")
assert.equal(Model.manifestVersion("not json", "oma.nearby"), "")

// SemVer precedence, including the rule the release process depends on: a
// prerelease sorts below the release it leads up to, so a checkout on 1.1.0-dev
// is not satisfied by the 1.1.0 floor it is heading for and 1.1.0 is not held
// back by a 1.1.0-dev helper.
assert.equal(Model.compareVersions("1.0.0", "1.0.0"), 0)
assert.equal(Model.compareVersions("1.2.0", "1.10.0"), -1)
assert.equal(Model.compareVersions("2.0.0", "1.99.99"), 1)
assert.equal(Model.compareVersions("1.1.0-dev", "1.1.0"), -1)
assert.equal(Model.compareVersions("1.1.0", "1.1.0-dev"), 1)
assert.equal(Model.compareVersions("1.1.0-dev.2", "1.1.0-dev.10"), -1)
assert.equal(Model.compareVersions("1.1.0-alpha", "1.1.0-beta"), -1)
assert.equal(Model.compareVersions("1.1.0-1", "1.1.0-alpha"), -1)
assert.equal(Model.compareVersions("1.0", "1.0.0"), null, "an unreadable version is unknown, not equal")
assert.equal(Model.compareVersions("", "1.0.0"), null)

// The floor is what a source-only `omarchy plugin update` has to survive: the
// checkout moves ahead of the helper, and a helper that still speaks the same
// commands must keep working instead of stopping the plugin dead.
assert.equal(Model.helperSatisfies("1.0.6", "1.0.6"), true)
assert.equal(Model.helperSatisfies("1.0.6", "1.0.7"), true, "a helper past the floor is still usable")
assert.equal(Model.helperSatisfies("1.0.6", "1.0.5"), false)
assert.equal(Model.helperSatisfies("1.1.0", "1.1.0-dev"), false, "a prerelease is below the release")
assert.equal(Model.helperSatisfies("1.0.6", ""), false, "no version reported is not a version that passes")
assert.equal(Model.helperSatisfies("", "1.0.6"), false, "no floor known is not a floor that passes")

assert.equal(Model.manifestMinHelperVersion('{"id":"oma.nearby","version":"1.1.0","minHelperVersion":"1.0.6"}', "oma.nearby"), "1.0.6")
assert.equal(Model.manifestMinHelperVersion('{"id":"oma.nearby","version":"1.1.0"}', "oma.nearby"), "",
  "a manifest without the field declares no floor, and the service falls back to its own version")
assert.equal(Model.manifestMinHelperVersion('{"id":"other.plugin","minHelperVersion":"1.0.6"}', "oma.nearby"), "")
assert.equal(Model.manifestMinHelperVersion("not json", "oma.nearby"), "")
// The service reads its own entry out of shell.json. An absent entry is a
// config that has not been applied yet, which is why it is null rather than an
// empty settings object: the receiver stays off until the entry is seen, so a
// persisted off is never briefly treated as on.
//
// `source` is where a settings write would land, and it mirrors the order
// shell.qml:1078 updateEntryInline() searches, so the value read back is the
// value written.
const layoutOff = {version:1, bar:{layout:{left:[{id:"omarchy.menu"}], center:[], right:[{id:"b.omadoro"},{id:"oma.nearby",receiverEnabled:false}]}}, plugins:[]}
assert.deepEqual(Model.barEntry(layoutOff, "oma.nearby"),
  {id:"oma.nearby", settings:{receiverEnabled:false}, source:"layout", targetSettings:{receiverEnabled:false}})
assert.equal(Model.receiverEnabledIn(Model.barEntry(layoutOff, "oma.nearby")), false)
assert.equal(Model.entryWritable(Model.barEntry(layoutOff, "oma.nearby")), true)

const layoutDefault = {version:1, bar:{layout:{right:[{id:"oma.nearby"}]}}, plugins:[]}
assert.deepEqual(Model.barEntry(layoutDefault, "oma.nearby"),
  {id:"oma.nearby", settings:{}, source:"layout", targetSettings:{}})
assert.equal(Model.receiverEnabledIn(Model.barEntry(layoutDefault, "oma.nearby")), true,
  "an entry with no receiver setting means on, the way it always has")

// --- the collapsed-config regression --------------------------------------
// On 4.0.3 this plugin read its settings from `shell.shellConfig`, which
// services/PluginShellApi.qml does not have: an installed third-party plugin
// gets `barConfig`, a copy of shellConfig.bar. Every read collapsed to null, so
// the receiver reported itself disabled while shell.json said it was on, and
// nothing it wrote could be read back. Both shapes must resolve, and both
// placements: on the bar, and hosted inside a drawer's items[].
{
  // What shell.barConfig actually is: shellConfig.bar, with no `bar` of its own
  // and no plugins[]. Verified live on 4.0.3 --
  // `omarchy-shell shell listShellConfig | jq '.bar | keys'` is
  // ["centerAnchor", "layout", "position", "transparent"].
  const barConfig = {position:"top", transparent:false, centerAnchor:"omarchy.clock",
    layout:{left:[], center:[{id:"oma.nearby", receiverEnabled:true}], right:[]}}
  const entry = Model.barEntry(barConfig, "oma.nearby")
  assert.notEqual(entry, null, "a bar-config shape must resolve, not collapse to null")
  assert.equal(Model.receiverEnabledIn(entry), true)
  assert.equal(entry.source, "layout")

  // Hosted inside a drawer. shell.qml's writer never looks inside items[], so
  // it writes the plugins[] marker, and the marker is what has to win.
  const hosted = {version:1, bar:{layout:{right:[
    {id:"t1nk33r.nook", items:[{id:"oma.nearby"}]}]}},
    plugins:[{id:"t1nk33r.nook"}, {id:"oma.nearby", receiverEnabled:false}]}
  const hostedEntry = Model.barEntry(hosted, "oma.nearby")
  assert.notEqual(hostedEntry, null, "a widget a drawer hosts must resolve too")
  assert.deepEqual(hostedEntry.settings, {receiverEnabled:false},
    "the drawer's items entry supplies the settings the marker does not carry")
  assert.equal(Model.receiverEnabledIn(hostedEntry), false,
    "and the marker, which is where a write lands, wins where they disagree")
  assert.equal(hostedEntry.source, "plugins")
  assert.deepEqual(hostedEntry.targetSettings, {receiverEnabled:false},
    "a write resends the marker's own keys, never the drawer's")
  assert.equal(Model.entryWritable(hostedEntry), true)

  // Hosted with no marker: the host writes nothing, and the plugin has to know
  // that rather than offer a control that springs back.
  const stranded = Model.barEntry({version:1, bar:{layout:{right:[
    {id:"t1nk33r.nook", items:[{id:"oma.nearby", receiverEnabled:false}]}]}}, plugins:[]}, "oma.nearby")
  assert.equal(stranded.source, "items")
  assert.equal(Model.entryWritable(stranded), false)
  assert.equal(Model.receiverEnabledIn(stranded), false)

  // Not configured must stay distinguishable from configured off. Both report
  // the receiver as not eligible; only the pair tells them apart.
  const absent = Model.barEntry({version:1, bar:{layout:{right:[]}}, plugins:[]}, "oma.nearby")
  const off = Model.barEntry({version:1, bar:{layout:{right:[{id:"oma.nearby", receiverEnabled:false}]}}, plugins:[]}, "oma.nearby")
  assert.equal(absent, null)
  assert.notEqual(off, null)
  assert.equal(Model.receiverEnabledIn(absent), false)
  assert.equal(Model.receiverEnabledIn(off), false)
  assert.notDeepEqual([absent !== null, Model.receiverEnabledIn(absent)],
    [off !== null, Model.receiverEnabledIn(off)],
    "an unread config and a persisted off must not present as the same state")
}

// Quattro accepts a widget id directly in a bar layout. It counts as
// configured, but it is not a write target: shell.qml's writer matches entries
// through entry.id, which a string does not have, so settings land on the
// plugins[] marker instead and are read back from there.
const layoutString = {version:1, bar:{layout:{right:["oma.nearby"]}}, plugins:[]}
assert.deepEqual(Model.barEntry(layoutString, "oma.nearby"),
  {id:"oma.nearby", settings:{}, source:"items", targetSettings:{}},
  "a matching string-form bar entry must be recognized as configured")
assert.equal(Model.receiverEnabledIn(Model.barEntry(layoutString, "oma.nearby")), true,
  "a string-form entry with no receiver setting must use the default-on behavior")
for (const region of ["left", "center", "right"]) {
  const config = {version:1, bar:{layout:{left:[], center:[], right:[]}}, plugins:[]}
  config.bar.layout[region] = ["oma.nearby"]
  assert.notEqual(Model.barEntry(config, "oma.nearby"), null,
    `a string-form entry in bar.layout.${region} must be recognized`)
}
{
  const stringWithMarker = {version:1, bar:{layout:{right:["other.before", "oma.nearby", {id:"other.after", x:1}]}},
    plugins:[{id:"oma.nearby", receiverEnabled:false}]}
  const entry = Model.barEntry(stringWithMarker, "oma.nearby")
  assert.equal(entry.source, "plugins",
    "a string entry cannot receive settings, so the marker beside it is the write target")
  assert.equal(Model.receiverEnabledIn(entry), false)
  assert.deepEqual(stringWithMarker.bar.layout.right, ["other.before", "oma.nearby", {id:"other.after", x:1}],
    "and reading must not rewrite the user's layout to get there")
}

// Duplicate placements: the host overwrites every top-level match with the same
// value, so the first one is the truth and a stale twin cannot swallow a write.
{
  const duplicated = {version:1, bar:{layout:{
    left:[{id:"oma.nearby", receiverEnabled:true}],
    right:[{id:"oma.nearby", receiverEnabled:false}]}}, plugins:[]}
  assert.equal(Model.receiverEnabledIn(Model.barEntry(duplicated, "oma.nearby")), true)
}

assert.equal(Model.barEntry(layoutDefault, "other.plugin"), null)
assert.equal(Model.barEntry({version:1, bar:{layout:{right:[]}}, plugins:[]}, "oma.nearby"), null)
assert.equal(Model.barEntry(null, "oma.nearby"), null)
assert.equal(Model.barEntry(undefined, "oma.nearby"), null)
assert.equal(Model.barEntry({}, "oma.nearby"), null)
assert.equal(Model.barEntry(layoutDefault, ""), null)
assert.equal(Model.entryWritable(null), false)
assert.equal(Model.receiverEnabledIn(null), false,
  "no entry means the receiver is not eligible to run yet, not that it defaults to on")
assert.equal(Model.receiverEnabledIn({id:"oma.nearby"}), false,
  "and an entry with no settings at all must not throw its way to eligible")

// Non-widget plugin entries live in plugins[] instead of the bar layout.
assert.deepEqual(Model.barEntry({version:1, plugins:[{id:"oma.nearby",receiverEnabled:false}]}, "oma.nearby"),
  {id:"oma.nearby", settings:{receiverEnabled:false}, source:"plugins", targetSettings:{receiverEnabled:false}})
// Malformed entries must not throw or match. String entries are valid only in
// the bar layout; Quattro's top-level plugins[] lookup requires object entries.
assert.equal(Model.barEntry({version:1, bar:{layout:{right:[null,"other.plugin",42]}}}, "oma.nearby"), null)
assert.equal(Model.barEntry({version:1, plugins:["oma.nearby"]}, "oma.nearby"), null)

// The settings document is parsed here so the QML has no JSON handling of its
// own. Unreadable is null, which the service holds as not-yet-known rather than
// as an empty config: an unreadable shell.json must not start a receiver the
// user turned off.
assert.deepEqual(Model.shellConfigIn('{"version":1,"plugins":[]}'), {version:1, plugins:[]})
assert.equal(Model.shellConfigIn("not json"), null)
assert.equal(Model.shellConfigIn(""), null)
assert.equal(Model.shellConfigIn("   "), null)
assert.equal(Model.shellConfigIn(null), null)
assert.equal(Model.shellConfigIn("[1,2]"), null, "a document that is not an object is not a config")


// --- device name -----------------------------------------------------------
// ROBUSTNESS.md item 10: names containing markup must render literally. The
// shared UI kit renders device rows with Qt's AutoText, so neutralising has to
// happen here rather than at the render site.
assert.equal(Model.displayName("<b>Phone</b>"), "bPhone/b")
assert.equal(Model.displayName("<img src=x>"), "img src=x")
assert.equal(Model.displayName("Phone\nName"), "Phone Name", "a newline must not break the row")
assert.equal(Model.displayName("Phone\u0007Name"), "Phone Name", "control characters are neutralised")
assert.equal(Model.displayName("  Phone  "), "Phone")
assert.equal(Model.displayName(""), "")
assert.equal(Model.displayName(null), "")
assert.equal(Model.displayName(undefined), "")
assert.equal(Model.displayName("x".repeat(200)).length, 64, "an over-long name is capped")
assert.equal(Model.displayName("Ok Name"), "Ok Name", "an ordinary name is unchanged")
assert.equal(Model.displayName("Phone \u2764"), "Phone \u2764", "emoji survive")
assert.equal(Model.upsertDevice([], {alias:"<b>P</b>", fingerprint:"fp"})[0].alias, "bP/b",
  "the LocalSend ingestion point neutralises aliases")

assert.equal(Model.deviceNameModeIn(null), "hostname")
assert.equal(Model.deviceNameModeIn({}), "hostname")
assert.equal(Model.deviceNameModeIn({settings:{}}), "hostname")
assert.equal(Model.deviceNameModeIn({settings:{deviceNameMode:"generated"}}), "generated")
assert.equal(Model.deviceNameModeIn({settings:{deviceNameMode:"custom"}}), "custom")
assert.equal(Model.deviceNameModeIn({settings:{deviceNameMode:"nonsense"}}), "hostname",
  "an unknown mode falls back rather than advertising nothing")
assert.equal(Model.customDeviceNameIn(null), "")
assert.equal(Model.customDeviceNameIn({settings:{deviceName:"Box"}}), "Box")

// Seeded, not random: a name that changed per launch would show up on the
// phone as a brand-new device every time.
assert.equal(Model.generatedDeviceName("fp"), Model.generatedDeviceName("fp"), "generation is deterministic")
assert.notEqual(Model.generatedDeviceName("fp-a"), Model.generatedDeviceName("fp-b"))
assert.match(Model.generatedDeviceName("fp"), /^[A-Z][a-z]+ [A-Z][a-z]+$/)

assert.equal(Model.resolveDeviceName({settings:{}}, "luna", "fp"), "luna")
assert.equal(Model.resolveDeviceName({settings:{deviceNameMode:"custom",deviceName:"My Box"}}, "luna", "fp"), "My Box")
assert.equal(Model.resolveDeviceName({settings:{deviceNameMode:"custom",deviceName:""}}, "luna", "fp"), "luna",
  "an empty custom name falls back instead of advertising nothing")
assert.equal(Model.resolveDeviceName({settings:{deviceNameMode:"generated"}}, "luna", "fp"),
  Model.generatedDeviceName("fp"))
assert.notEqual(Model.resolveDeviceName({settings:{}}, "", "fp"), "",
  "an unknown hostname still yields a usable name")
assert.equal(Model.resolveDeviceName({settings:{deviceNameMode:"custom",deviceName:"<b>x</b>"}}, "luna", "fp"), "bx/b",
  "a user-typed name is sanitised like a remote one")
assert.equal(Model.resolveDeviceName({settings:{deviceNameMode:"custom",deviceName:"y".repeat(80)}}, "luna", "fp").length, 32,
  "a custom name is capped at the advertised limit")


// A leading hyphen makes the name parse as a flag where it reaches the Quick
// Share CLI as `--name <value>`; verified against the binary, "-Luna" produced
// "unexpected argument '-L' found" and killed every invocation. Interior
// hyphens are legitimate and must survive.
assert.equal(Model.displayName("-Luna"), "Luna")
assert.equal(Model.displayName("--x"), "x")
assert.equal(Model.displayName("+Plus"), "Plus")
assert.equal(Model.displayName("a-b"), "a-b", "an interior hyphen is not a flag")
assert.equal(Model.displayName("-"), "")

// The pane's Generated button and the engine's advertised name must be the same
// string. They were seeded differently -- fingerprint vs hostname -- so the
// panel showed one name and the machine advertised another.
assert.equal(Model.resolveDeviceName({settings:{deviceNameMode:"generated"}}, "luna", "luna"),
  Model.generatedDeviceName("luna"),
  "generated mode must advertise exactly what the pane previews")


// The hostname reaches a kit Button label, and the kit renders labels with Qt's
// default AutoText -- so it is neutralised where it enters, not where it is
// drawn. Applying it twice (ingestion, then resolveDeviceName) must be safe.
assert.equal(Model.displayName("<b>host</b>", 64), "bhost/b")
assert.equal(Model.displayName(Model.displayName("<b>host</b>", 64), 64), "bhost/b",
  "sanitising is idempotent, so the ingestion pass and resolveDeviceName cannot compound")
assert.equal(Model.displayName(Model.displayName("Phone \u2764", 64), 64), "Phone \u2764",
  "and it still leaves emoji alone on the second pass")

console.log("Model tests passed")
