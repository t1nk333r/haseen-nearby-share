function parseLine(line) {
  try { return JSON.parse(String(line || "")) } catch (e) { return null }
}

// The Rust peer registry keeps at most this many peers, and the QML device
// array is that registry's frontend mirror. The same bound applies here so
// LAN identity churn cannot grow the frontend list without limit while the
// discovery view is closed. One limit, one place.
var MAX_DEVICES = 256

function upsertDevice(devices, device) {
  if (!device || !device.fingerprint || !device.alias) return devices || []
  var next = (devices || []).slice()
  var found = -1
  for (var i = 0; i < next.length; i++) if (next[i].fingerprint === device.fingerprint) { found = i; break }
  var row = {
    alias: displayName(device.alias), version: String(device.version || "2.1"), deviceModel: String(device.deviceModel || ""),
    deviceType: String(device.deviceType || "desktop"), fingerprint: String(device.fingerprint),
    port: Number(device.port || 53317), protocol: String(device.protocol || "https"),
    download: device.download === true, ip: String(device.ip || "")
  }
  if (found < 0) next.push(row); else next[found] = row
  next.sort(function(a, b) { return a.alias.localeCompare(b.alias) })
  if (next.length > MAX_DEVICES) next.length = MAX_DEVICES
  return next
}

function snapshotDevices(snapshot) {
  var next = []
  for (var i = 0; i < (snapshot || []).length; i++) next = upsertDevice(next, snapshot[i])
  return next
}

function iconFor(type) {
  if (type === "mobile") return "󰄜"
  if (type === "web") return "󰖟"
  if (type === "server" || type === "headless") return "󰒋"
  return "󰍹"
}

function formatBytes(bytes) {
  var value = Number(bytes || 0)
  if (value < 1024) return value + " B"
  var units = ["KB", "MB", "GB", "TB"], i = -1
  do { value /= 1024; i++ } while (value >= 1024 && i < units.length - 1)
  return value.toFixed(value >= 10 ? 0 : 1) + " " + units[i]
}

function incomingSummary(files) {
  if (!files || files.length === 0) return "Transfer"
  if (files.length === 1) return String(files[0].name || "Transfer")
  return String(files[0].name || "Transfer") + " + " + (files.length - 1) + " more"
}

function enqueueIncoming(queue, request) {
  var next = (queue || []).slice()
  if (!request || !request.requestId) return next
  for (var i = 0; i < next.length; i++) {
    if (next[i] && next[i].requestId === request.requestId) {
      next[i] = request
      return next
    }
  }
  next.push(request)
  return next
}

function removeIncoming(queue, requestId) {
  return (queue || []).filter(function(request) {
    return request && request.requestId !== requestId
  })
}

function currentIncoming(queue) {
  return queue && queue.length ? queue[0] : null
}

function outgoingCommand(pending, transferId, pin) {
  if (!pending || !pending.device || (pending.kind !== "files" && pending.kind !== "text")) return null
  var command = {command:pending.kind === "files" ? "send_files" : "send_text", transfer_id:transferId, device:pending.device}
  if (pending.kind === "files") command.paths = (pending.paths || []).slice()
  else command.text = String(pending.text || "")
  if (typeof pin === "string" && pin !== "") command.pin = pin
  return command
}

function viewAfterOutgoing(hasPendingIncoming, terminalState) {
  return hasPendingIncoming ? "incoming" : terminalState
}

// ------------------------------------------------------------- shell.json
//
// Settings live in ~/.config/omarchy/shell.json and nowhere else.
//
// The service reads them from the config rather than waiting for a bar widget
// to hand them over. Widgets are built once per monitor and get their
// `settings` injected a tick after they are created, so a widget cannot report
// the persisted state at the moment it starts up, and several widgets
// reporting the same state is redundant rather than authoritative.
//
// These functions take the whole document, because the answer is spread across
// two places the host treats as one: an entry in bar.layout, and a marker in
// the top-level plugins[]. See barEntry.

var SECTIONS = ["left", "center", "right"]

function isPlainObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value)
}

// A `var` property handed over by the host arrives as a QVariant, so a JSON
// array in it fails Array.isArray. Index by length instead.
function isArrayLike(value) {
  return !!value && typeof value === "object" && value.length !== undefined
}

// Util.canonicalWidgetId in the host is the identity function, so an id is its
// own canonical form. Not String(id) straight away: String(undefined) is
// "undefined", which would give every id-less entry the same phantom id.
function entryIdOf(entry) {
  var id = isPlainObject(entry) ? entry.id : entry
  return id === undefined || id === null ? "" : String(id)
}

// Everything an entry carries except its id -- the shape the host injects as a
// widget's `settings` and the shape it writes back. `items` is deliberately
// included: a write replaces the whole entry, so dropping it here would delete
// a drawer's contents on the first settings change.
function entrySettings(entry) {
  var out = {}
  if (!isPlainObject(entry)) return out
  for (var key in entry) if (key !== "id") out[key] = entry[key]
  return out
}

// Accepts either a whole shell.json document (`config.bar.layout`) or the bar
// config the host hands a plugin as shell.barConfig (`config.layout`), which is
// a copy of shellConfig.bar and has no `bar` of its own.
function layoutSectionsIn(config) {
  if (!isPlainObject(config)) return null
  var bar = isPlainObject(config.bar) ? config.bar : config
  return isPlainObject(bar.layout) ? bar.layout : null
}

// Every placement of one id in the layout, at any depth. Depth 0 is a section
// entry; deeper is a widget hosted inside another widget's `items[]`, which is
// how a drawer (t1nk33r.nook) carries the widgets it absorbed.
function collectLayoutMatches(list, id, depth, out) {
  if (!isArrayLike(list)) return out
  for (var i = 0; i < list.length; i++) {
    var entry = list[i]
    if (entryIdOf(entry) === id)
      out.push({ depth: depth, object: isPlainObject(entry), settings: entrySettings(entry) })
    if (isPlainObject(entry) && isArrayLike(entry.items))
      collectLayoutMatches(entry.items, id, depth + 1, out)
  }
  return out
}

function layoutMatchesIn(config, id) {
  var out = []
  var layout = layoutSectionsIn(config)
  if (!layout || id === "") return out
  for (var s = 0; s < SECTIONS.length; s++) collectLayoutMatches(layout[SECTIONS[s]], id, 0, out)
  return out
}

// The first plugins[] marker for this id, or null. Only an object marker can
// carry settings; the host writes `{id: ...}` over whatever was there.
function markerSettingsIn(config, id) {
  var plugins = isPlainObject(config) && isArrayLike(config.plugins) ? config.plugins : null
  if (!plugins || id === "") return null
  for (var i = 0; i < plugins.length; i++) {
    if (entryIdOf(plugins[i]) !== id) continue
    if (!isPlainObject(plugins[i])) continue
    return entrySettings(plugins[i])
  }
  return null
}

// The plugin's own settings, and where a write to them lands.
//
// Null means "shell.json has not been read yet", not "no settings": the shell
// only keeps this plugin loaded while an entry exists, so nothing found is a
// config that has not arrived rather than one that says nothing. Callers pair
// this with receiverEnabledIn, which reports off for null -- the two together
// distinguish "not configured" from "configured off".
//
// `source` is the entry shell.qml:1078 updateEntryInline() would write, and the
// merge precedence is that same order, so what the plugin reads back is what it
// wrote:
//
//   layout  a top-level object entry in bar.layout. Every top-level match is
//           overwritten with the same value, so the first one is the truth.
//   plugins the plugins[] marker, used when no top-level object entry matches.
//           A bare string in bar.layout is not a write target: the host matches
//           entries through entry.id, which a string does not have.
//   items   hosted inside a drawer and with no marker. The host writes nothing,
//           so a settings change cannot persist; entryWritable reports false.
//
// A drawer's items[] entry is the lowest precedence because the host never
// writes it, which is also how t1nk33r.nook reads a widget it hosts
// (LayoutModel.js hostedSettings).
//
// Kept over the upstream barEntry()/parseShellConfig()/hasStringBarEntry()/
// promoteStringBarEntry() set, which this local rewrite replaces: the two
// cannot coexist, so the local change wins here.
function barEntry(config, pluginId) {
  var id = String(pluginId || "")
  if (id === "") return null
  var matches = layoutMatchesIn(config, id)
  var marker = markerSettingsIn(config, id)
  if (!matches.length && marker === null) return null

  var top = null
  var nested = []
  for (var m = 0; m < matches.length; m++) {
    if (matches[m].depth === 0) {
      if (top === null && matches[m].object) top = matches[m].settings
      continue
    }
    nested.push(matches[m])
  }
  // Deepest first, so a shallower host's entry wins over the one it nests.
  nested.sort(function(left, right) { return right.depth - left.depth })

  var settings = {}
  var layers = nested.map(function(match) { return match.settings })
  if (marker !== null) layers.push(marker)
  if (top !== null) layers.push(top)
  for (var l = 0; l < layers.length; l++)
    for (var key in layers[l]) settings[key] = layers[l][key]

  return {
    id: id,
    settings: settings,
    source: top !== null ? "layout" : (marker !== null ? "plugins" : "items"),
    // The write target's own keys. A write replaces the whole entry, so it has
    // to resend them -- and only them, or the merged view's foreign keys would
    // be copied onto a target that never held them.
    targetSettings: top !== null ? top : (marker !== null ? marker : {})
  }
}

// Whether a settings write can land anywhere. False for a widget a drawer hosts
// with no plugins[] marker beside it: updateEntryInline() searches bar.layout's
// top level and plugins[], never a drawer's items, so there is nothing to write.
function entryWritable(entry) {
  return !!entry && (entry.source === "layout" || entry.source === "plugins")
}

// The plugins[] markers are not on any 4.0.3 plugin API surface --
// services/PluginShellApi.qml carries barConfig (a copy of shellConfig.bar) and
// no shellConfig, and services/PluginRegistryApi.qml carries this plugin's
// manifest and nothing else -- so the service reads the document the host
// writes. Parsing is here, where it can be tested, rather than in the QML.
//
// Null is "unreadable", which the service holds as not-yet-known rather than as
// an empty config: an unreadable shell.json must not start a receiver the user
// turned off.
function shellConfigIn(text) {
  var raw = String(text || "")
  if (raw.trim() === "") return null
  var parsed = null
  try { parsed = JSON.parse(raw) } catch (e) { return null }
  return isPlainObject(parsed) ? parsed : null
}

// Receiving is on unless the entry says otherwise, and off until the entry
// exists at all, so a persisted "off" cannot be missed while the config is
// still loading. Off with no entry and off with a persisted false read the
// same here on purpose -- the pair (barEntry() !== null, this) is what tells
// them apart, and both mean "do not start the helper".
function receiverEnabledIn(entry) {
  return !!entry && !!entry.settings && entry.settings.receiverEnabled !== false
}

// Remote device names arrive from unauthenticated LAN advertisements, and the
// shared Omarchy UI kit renders Button.text and PanelHero.title/meta with Qt's
// default AutoText, which turns anything that looks like markup into markup.
// The plugin cannot set textFormat on those elements, so names are neutralised
// here instead -- once, at the boundary, covering every downstream sink.
// ROBUSTNESS.md item 10 requires such names render literally.
function displayName(value, limit) {
  var text = String(value === undefined || value === null ? "" : value)
  var max = Number(limit || 64)
  text = text.replace(/[<>]/g, "").replace(/[\x00-\x1F\x7F]/g, " ")
  text = text.replace(/\s+/g, " ").trim()
  // Keep a name that reaches another program from being parsed as an option.
  // Interior hyphens are ordinary text and must survive.
  text = text.replace(/^[-+]+/, "").trim()
  if (text.length > max) text = text.slice(0, max - 1) + "\u2026"
  return text
}

// Where the advertised name comes from. Only the mode and the custom string are
// persisted; hostname and generated are derived, so they cannot go stale.
function deviceNameModeIn(entry) {
  var mode = entry && entry.settings ? String(entry.settings.deviceNameMode || "") : ""
  return (mode === "hostname" || mode === "generated" || mode === "custom") ? mode : "hostname"
}

function customDeviceNameIn(entry) {
  return entry && entry.settings ? String(entry.settings.deviceName || "") : ""
}

// Deterministic from the seed. A name that changed on every launch would appear
// on the phone as a brand-new device each time, so this is seeded rather than
// random and needs no persistence of its own.
function generatedDeviceName(seed) {
  var adjectives = ["Amber", "Brisk", "Calm", "Copper", "Dusty", "Eager", "Fleet", "Glass",
                    "Hazel", "Ivory", "Jolly", "Keen", "Lucky", "Mellow", "Noble", "Olive",
                    "Plucky", "Quiet", "Rapid", "Silver", "Tidy", "Umber", "Vivid", "Warm"]
  var nouns = ["Otter", "Badger", "Falcon", "Heron", "Lynx", "Marten", "Osprey", "Puffin",
               "Raven", "Shrew", "Stoat", "Tern", "Vole", "Weasel", "Wren", "Ibis",
               "Kestrel", "Magpie", "Nuthatch", "Pika", "Quail", "Redwing", "Sable", "Teal"]
  var text = String(seed || "")
  var hash = 0
  for (var i = 0; i < text.length; i++) hash = ((hash * 31) + text.charCodeAt(i)) >>> 0
  return adjectives[hash % adjectives.length] + " " + nouns[(hash >>> 8) % nouns.length]
}

// Never returns empty: an empty alias makes the helper advertise nothing useful,
// so every branch falls through to a generated name rather than to "".
function resolveDeviceName(entry, hostname, seed) {
  var mode = deviceNameModeIn(entry)
  var custom = displayName(customDeviceNameIn(entry), 32)
  var host = displayName(hostname, 32)
  if (mode === "custom" && custom !== "") return custom
  if (mode === "generated") return generatedDeviceName(seed || host || "nearby")
  if (host !== "") return host
  return generatedDeviceName(seed || "nearby")
}

function helperVersionMatches(pluginVersion, helperVersion) {
  return String(pluginVersion || "") !== "" && String(pluginVersion) === String(helperVersion || "")
}

// Nearby's release process only ever produces MAJOR.MINOR.PATCH with an
// optional prerelease suffix, so that is all this reads. Anything else is
// null, which callers treat as unknown rather than as equal: a version that
// cannot be read is not one the plugin can vouch for.
function parseVersion(value) {
  const match = /^(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+))?$/.exec(String(value || "").trim())
  if (!match) return null
  return {
    release: [Number(match[1]), Number(match[2]), Number(match[3])],
    prerelease: match[4] ? match[4].split(".") : []
  }
}

// SemVer precedence: numeric fields compare as numbers, a prerelease sorts
// before the release it leads up to, and prerelease identifiers compare as
// numbers when both are numeric and as text otherwise.
function compareVersions(left, right) {
  const a = parseVersion(left)
  const b = parseVersion(right)
  if (!a || !b) return null
  for (var i = 0; i < 3; i++) {
    if (a.release[i] !== b.release[i]) return a.release[i] < b.release[i] ? -1 : 1
  }
  if (a.prerelease.length === 0 || b.prerelease.length === 0) {
    if (a.prerelease.length === b.prerelease.length) return 0
    return a.prerelease.length === 0 ? 1 : -1
  }
  const longest = Math.max(a.prerelease.length, b.prerelease.length)
  for (var j = 0; j < longest; j++) {
    if (j >= a.prerelease.length) return -1
    if (j >= b.prerelease.length) return 1
    const x = a.prerelease[j]
    const y = b.prerelease[j]
    const xNumeric = /^\d+$/.test(x)
    const yNumeric = /^\d+$/.test(y)
    if (xNumeric && yNumeric) {
      if (Number(x) !== Number(y)) return Number(x) < Number(y) ? -1 : 1
      continue
    }
    if (xNumeric !== yNumeric) return xNumeric ? -1 : 1
    if (x !== y) return x < y ? -1 : 1
  }
  return 0
}

// A helper is good enough when it is at least the oldest one this plugin knows
// how to drive. This keeps plugin-only releases compatible with the independently
// versioned helper. An unreadable version on either side is still a refusal.
function helperSatisfies(requiredVersion, helperVersion) {
  const order = compareVersions(helperVersion, requiredVersion)
  return order !== null && order >= 0
}

function manifestVersion(text, pluginId) {
  try {
    const manifest = JSON.parse(String(text || ""))
    if (String(manifest.id || "") !== String(pluginId || "")) return ""
    return String(manifest.version || "")
  } catch (_) {
    return ""
  }
}

// The oldest helper this plugin can drive, declared beside the version it
// ships with. Absent means "the shipped version", which is the rule the plugin
// followed before the field existed and the safe reading of a manifest that
// predates it.
function manifestMinHelperVersion(text, pluginId) {
  try {
    const manifest = JSON.parse(String(text || ""))
    if (String(manifest.id || "") !== String(pluginId || "")) return ""
    return String(manifest.minHelperVersion || "")
  } catch (_) {
    return ""
  }
}

if (typeof module !== "undefined") module.exports = { parseLine, upsertDevice, snapshotDevices, iconFor, formatBytes, incomingSummary, enqueueIncoming, removeIncoming, currentIncoming, outgoingCommand, viewAfterOutgoing, barEntry, entryWritable, shellConfigIn, receiverEnabledIn, displayName, deviceNameModeIn, customDeviceNameIn, generatedDeviceName, resolveDeviceName, helperVersionMatches, compareVersions, helperSatisfies, manifestVersion, manifestMinHelperVersion, MAX_DEVICES }
