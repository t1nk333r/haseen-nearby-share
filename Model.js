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

// The plugin's own entry in shell.json, or null when it is not there yet.
//
// The service reads its settings from the shell config rather than waiting for
// a bar widget to hand them over. Widgets are built once per monitor and get
// their `settings` injected a tick after they are created, so a widget cannot
// report the persisted state at the moment it starts up, and several widgets
// reporting the same state is redundant rather than authoritative.
//
// Null means "shell.json has not been applied yet", not "no settings": the
// shell only keeps this plugin loaded while the entry exists, so an absent
// entry is a config that has not arrived rather than one that says nothing.
function barEntry(config, pluginId) {
  var id = String(pluginId || "")
  if (!config || typeof config !== "object" || id === "") return null
  var layout = config.bar && typeof config.bar === "object" ? config.bar.layout : null
  var regions = ["left", "center", "right"]
  for (var r = 0; r < regions.length; r++) {
    var entries = layout && Array.isArray(layout[regions[r]]) ? layout[regions[r]] : []
    for (var e = 0; e < entries.length; e++) {
      var entry = entries[e]
      if (typeof entry === "string") {
        if (entry === id) return { id: id, settings: {} }
        continue
      }
      if (!entry || typeof entry !== "object") continue
      if (String(entry.id || "") !== id) continue
      var settings = {}
      for (var key in entry) if (key !== "id") settings[key] = entry[key]
      return { id: String(entry.id), settings: settings }
    }
  }
  var plugins = Array.isArray(config.plugins) ? config.plugins : []
  for (var p = 0; p < plugins.length; p++) {
    var plugin = plugins[p]
    if (!plugin || typeof plugin !== "object" || String(plugin.id || "") !== id) continue
    var pluginSettings = {}
    for (var pluginKey in plugin) if (pluginKey !== "id") pluginSettings[pluginKey] = plugin[pluginKey]
    return { id: String(plugin.id), settings: pluginSettings }
  }
  return null
}

// A compatibility config read from disk on hosts whose scoped plugin API no
// longer injects shell.json. Anything that is not an object is a config that
// has not arrived: null keeps the receiver off until a valid file exists.
function parseShellConfig(text) {
  try {
    const parsed = JSON.parse(String(text || ""))
    return parsed && typeof parsed === "object" && !Array.isArray(parsed) ? parsed : null
  } catch (_) {
    return null
  }
}

// Quattro accepts a bare id in bar.layout, but its inline-settings writer can
// only attach settings to object entries. Promote a matching string in place
// before writing the first setting; top-level plugins[] does not accept this
// form in the host and is deliberately excluded.
function hasStringBarEntry(config, pluginId) {
  var id = String(pluginId || "")
  var layout = config && config.bar && typeof config.bar === "object" ? config.bar.layout : null
  if (!layout || id === "") return false
  var regions = ["left", "center", "right"]
  for (var r = 0; r < regions.length; r++) {
    var entries = Array.isArray(layout[regions[r]]) ? layout[regions[r]] : []
    for (var e = 0; e < entries.length; e++) if (entries[e] === id) return true
  }
  return false
}

function promoteStringBarEntry(config, pluginId, settings) {
  var id = String(pluginId || "")
  var layout = config && config.bar && typeof config.bar === "object" ? config.bar.layout : null
  if (!layout || id === "") return false
  var regions = ["left", "center", "right"]
  for (var r = 0; r < regions.length; r++) {
    var entries = Array.isArray(layout[regions[r]]) ? layout[regions[r]] : []
    for (var e = 0; e < entries.length; e++) {
      if (entries[e] !== id) continue
      var promoted = { id: id }
      for (var key in settings) if (key !== "id") promoted[key] = settings[key]
      entries[e] = promoted
      return true
    }
  }
  return false
}

// Receiving is on unless the entry says otherwise, and off until the entry
// exists at all, so a persisted "off" cannot be missed while the config is
// still loading.
function receiverEnabledIn(entry) {
  return !!entry && entry.settings.receiverEnabled !== false
}

// Which pane the two buttons last left selected. Anything unrecognised falls
// back to localsend, which is the pane that works without a build step.
function modeIn(entry) {
  var mode = entry && entry.settings ? String(entry.settings.mode || "") : ""
  return mode === "quickshare" ? "quickshare" : "localsend"
}

// `qs` reports phone/tablet/computer/device; the LocalSend helper reports
// mobile/web/server/headless. Two vocabularies for one icon set, so the Quick
// Share names are mapped rather than added to iconFor's.
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

function quickShareIconFor(type) {
  if (type === "phone" || type === "tablet") return iconFor("mobile")
  return iconFor("desktop")
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

if (typeof module !== "undefined") module.exports = { parseLine, upsertDevice, snapshotDevices, iconFor, formatBytes, incomingSummary, enqueueIncoming, removeIncoming, currentIncoming, outgoingCommand, viewAfterOutgoing, parseShellConfig, barEntry, hasStringBarEntry, promoteStringBarEntry, receiverEnabledIn, modeIn, quickShareIconFor, displayName, deviceNameModeIn, customDeviceNameIn, generatedDeviceName, resolveDeviceName, helperVersionMatches, compareVersions, helperSatisfies, manifestVersion, manifestMinHelperVersion, MAX_DEVICES }
