import QtQuick
import Quickshell
import Quickshell.Io

// The Quick Share half of the plugin.
//
// LocalSend is spoken natively by bin/omarchy-nearby-helper, which holds a
// persistent JSON conversation over stdio. Quick Share has no such helper:
// rquickshare is a Tauri app that ignores argv, and rqs_lib is a library, not
// a daemon. What exists is `qs`, a CLI over a fork of rqs_lib, so this engine
// drives short-lived subprocesses instead of one long-lived one and keeps the
// same property names the panel already reads.
//
// The binary is bin/nearby-qs, never `qs` on PATH: /usr/bin/qs is Quickshell's
// own CLI. See scripts/dependencies.sh.
Item {
  id: root

  property string pluginDir: ""
  // Pinned rather than ephemeral so the firewall needs one open port instead
  // of the whole high range. scripts/setup_firewall.sh opens this exact port.
  property int port: 53318
  property int scanTimeout: 6
  // Shown to the phone. `--name` is a global flag on the CLI, so it has to
  // precede the subcommand; empty means "let qs pick", so it is omitted rather
  // than passed as an empty string it would advertise literally.
  property string advertisedName: ""

  readonly property string binary: pluginDir + "/bin/nearby-qs"

  // Dependency state, refreshed from scripts/dependencies.sh rather than
  // guessed. `available` is the one the panel gates on.
  property bool available: false
  property bool depsChecked: false
  property var missingDeps: []
  readonly property bool buildRequired: missingDeps.indexOf("qs") >= 0

  property var devices: []
  property bool scanning: false
  property var selectedDevice: null

  // Mirrors Service.qml's vocabulary so the panel can switch on the same
  // strings: nearby | target | sending | success | error.
  property string viewState: "nearby"
  property string statusText: "Quick Share is idle"
  property string errorText: ""
  property real progress: 0
  property string transferName: ""
  property string transferPeer: ""
  property string transferPin: ""
  property var pendingPaths: []

  signal cursorRequested(int index)

  function refreshDependencies() { if (!depsProbe.running) depsProbe.running = true }

  function noteDependencies(payload) {
    var parsed = null
    try { parsed = JSON.parse(payload) } catch (e) { parsed = null }
    if (!parsed || !parsed.deps) { depsChecked = true; return }
    var missing = []
    for (var i = 0; i < parsed.deps.length; i++)
      if (!parsed.deps[i].present) missing.push(parsed.deps[i].id)
    missingDeps = missing
    available = missing.indexOf("qs") < 0
    depsChecked = true
    if (!available && viewState === "nearby")
      statusText = "Quick Share CLI is not installed"
  }

  function scan() {
    if (!available || scanner.running) return
    scanning = true
    errorText = ""
    statusText = "Searching…"
    scanner.launched = false
    scanner.running = true
  }

  function noteDevices(payload) {
    var parsed = null
    try { parsed = JSON.parse(payload) } catch (e) { parsed = null }
    if (!parsed || !parsed.length) { devices = []; return }
    var next = []
    for (var i = 0; i < parsed.length; i++) {
      var d = parsed[i]
      // `id` is already "ip:port" and is exactly what `qs send --to` accepts,
      // so it is carried through untouched rather than rebuilt from ip/port.
      next.push({ alias: String(d.name || "Unknown"), id: String(d.id || ""),
                  deviceType: String(d.type || "device"), ip: String(d.ip || "") })
    }
    next.sort(function(a, b) { return a.alias.localeCompare(b.alias) })
    devices = next
  }

  function chooseDevice(index) {
    if (index < 0 || index >= devices.length) return
    selectedDevice = devices[index]
    viewState = "target"
    cursorRequested(0)
  }
  function clearTarget() { viewState = "nearby"; selectedDevice = null; cursorRequested(0) }

  function sendFiles(paths) {
    if (!available || !selectedDevice || sender.running) return
    if (!paths || !paths.length) return
    pendingPaths = paths
    progress = 0
    transferPin = ""
    transferName = paths.length === 1 ? String(paths[0]).split("/").pop() : paths.length + " files"
    transferPeer = selectedDevice.alias
    errorText = ""
    statusText = "Connecting…"
    viewState = "sending"
    sender.launched = false
    sender.running = true
  }

  // Everything `qs` says about a transfer goes to stderr as prose, so this is
  // a parser rather than a protocol. Only three shapes are load-bearing: the
  // PIN, the percentage ProgressUi emits every 10% when it is not on a TTY,
  // and the final confirmation. Anything else is left for the log.
  function noteSendLine(line) {
    var text = String(line || "")
    var pin = text.match(/\(PIN\s+([^)]+)\)/)
    if (pin) { transferPin = pin[1]; statusText = "Waiting for " + transferPeer + " to accept"; return }
    var pct = text.match(/^\s*(\d{1,3})%\s*$/)
    if (pct) {
      progress = Math.max(0, Math.min(1, Number(pct[1]) / 100))
      statusText = "Sending"
      return
    }
    if (text.indexOf("Sent") >= 0 && text.indexOf("file") >= 0) progress = 1
  }

  // Exit codes are the contract `qs` documents: 0 sent, 2 declined or timed
  // out or no device, 130 cancelled, anything else an error. The stderr prose
  // is not consulted here -- it has already been parsed for what it is worth.
  function finishSend(code) {
    pendingPaths = []
    transferPin = ""
    if (code === 0) {
      progress = 1
      viewState = "success"
      statusText = "Sent"
      return
    }
    if (code === 130) { viewState = "nearby"; statusText = "Cancelled"; selectedDevice = null; return }
    viewState = "error"
    errorText = code === 2
      ? "Declined by " + transferPeer + ", or it stopped responding."
      : "Quick Share could not send to " + transferPeer + "."
    statusText = errorText
  }

  function cancelSend() { if (sender.running) sender.signal(2) }
  function finishTerminal() {
    viewState = "nearby"
    errorText = ""
    statusText = available ? "Quick Share is idle" : "Quick Share CLI is not installed"
    selectedDevice = null
    progress = 0
    cursorRequested(0)
  }
  function failWith(message) { viewState = "error"; errorText = message; statusText = message }

  Process {
    id: depsProbe
    command: ["bash", root.pluginDir + "/scripts/dependencies.sh", "--json"]
    running: false
    stdout: StdioCollector { id: depsOutput; waitForEnd: true }
    onExited: function(code) { root.noteDependencies(String(depsOutput.text || "")) }
  }

  Process {
    id: scanner
    property bool launched: false
    command: {
      var argv = [root.binary, "--port", String(root.port)]
      if (root.advertisedName !== "") { argv.push("--name"); argv.push(root.advertisedName) }
      argv.push("devices"); argv.push("--json"); argv.push("--timeout"); argv.push(String(root.scanTimeout))
      return argv
    }
    running: false
    stdout: StdioCollector { id: scanOutput; waitForEnd: true }
    stderr: SplitParser { onRead: function(line) { console.warn("quickshare devices", line) } }
    onStarted: scanner.launched = true
    // A command that never launches returns running to false without ever
    // emitting started or exited, so a missing binary has to be caught here.
    onRunningChanged: {
      if (running || scanner.launched) return
      root.scanning = false
      root.available = false
      root.errorText = "The Quick Share CLI is not installed."
    }
    onExited: function(code) {
      root.scanning = false
      if (code === 0) {
        root.noteDevices(String(scanOutput.text || ""))
        root.statusText = root.devices.length ? "Ready" : "No devices nearby"
      } else {
        root.errorText = "Quick Share could not search for devices."
        root.statusText = root.errorText
      }
    }
  }

  Process {
    id: sender
    property bool launched: false
    // --to is mandatory off a TTY, and `qs` exits 2 rather than prompting if
    // it is missing. The device id is passed rather than the name: a name
    // match is a substring search and two phones can share one.
    command: {
      var argv = [root.binary, "--port", String(root.port)]
      if (root.advertisedName !== "") { argv.push("--name"); argv.push(root.advertisedName) }
      argv.push("send")
      for (var i = 0; i < root.pendingPaths.length; i++) argv.push(String(root.pendingPaths[i]))
      argv.push("--to")
      argv.push(root.selectedDevice ? String(root.selectedDevice.id) : "")
      return argv
    }
    running: false
    stderr: SplitParser { onRead: function(line) { root.noteSendLine(line) } }
    onStarted: sender.launched = true
    onRunningChanged: {
      if (running || sender.launched) return
      root.pendingPaths = []
      root.failWith("The Quick Share CLI is not installed.")
    }
    onExited: function(code) { root.finishSend(code) }
  }

  Component.onCompleted: refreshDependencies()
}
