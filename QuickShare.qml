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

  // Dependency AND radio state, both refreshed from scripts/dependencies.sh
  // rather than guessed. `available` is the one the panel gates on, and it is
  // the conjunction: the CLI can be installed and the radio still not ready --
  // a desktop that lives on Ethernet is the ordinary case here -- so the
  // probe's radio verdict is part of it and its sentence is what the pane
  // shows. Nothing is hand-set: the engine comes back by itself on the day the
  // radio does.
  property bool available: false
  property bool depsChecked: false
  property var missingDeps: []
  readonly property bool buildRequired: missingDeps.indexOf("qs") >= 0
  property bool radioReady: false
  property string radioReason: ""

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

  // One sentence for "this engine cannot run", used by the probe handler and by
  // the exit from a finished transfer both. A missing CLI and a radio that is
  // down are different faults with different fixes, and the second one used to
  // be reported as the first: after a transfer ended on a machine whose Wi-Fi
  // had gone down, the pane claimed the CLI was not installed.
  function unavailableStatus() {
    if (missingDeps.indexOf("qs") >= 0) return "Quick Share CLI is not installed"
    return radioReason !== "" ? "Quick Share cannot run: " + radioReason : "Quick Share is unavailable"
  }

  function noteDependencies(payload) {
    var parsed = null
    try { parsed = JSON.parse(payload) } catch (e) { parsed = null }
    if (!parsed || !parsed.deps) { depsChecked = true; return }
    var missing = []
    for (var i = 0; i < parsed.deps.length; i++)
      if (!parsed.deps[i].present) missing.push(parsed.deps[i].id)
    missingDeps = missing
    // The radio half of the same report. A machine with every dependency and
    // the radio down is the ordinary desktop here, and it must not be told to
    // install something: `available` is the conjunction, and the reason is the
    // probe's own sentence, so both halves of the plugin word it the same.
    var radio = parsed.radio || null
    radioReady = radio ? radio.ready === true : false
    radioReason = radio && radio.reason ? String(radio.reason) : ""
    available = missing.indexOf("qs") < 0 && radioReady
    depsChecked = true
    if (!available && viewState === "nearby") statusText = unavailableStatus()
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
    statusText = available ? "Quick Share is idle" : unavailableStatus()
    selectedDevice = null
    progress = 0
    cursorRequested(0)
  }
  function failWith(message) { viewState = "error"; errorText = message; statusText = message }

  // Set before anything else is torn down. A shell.json write rebuilds the
  // plugin tree, so this engine is destroyed and rebuilt routinely, not only at
  // shutdown, and every `qs` subprocess below outlives it: `dependencies.sh`
  // takes a moment, a scan takes six seconds, a send takes as long as the phone
  // does. Their handlers are the Process's own code and still run, but the
  // engine they call into is already gone -- QObjectPrivate::deleteChildren
  // runs after the parent's QML metaobject is destroyed, so a function on it
  // reads undefined and calling it throws inside the destruction path. That is
  // the logged TypeError: "Property 'noteDependencies' of object
  // QuickShare_QMLTYPE_1072 is not a function" at line -1, from depsProbe's
  // onExited after a hot reload.
  //
  // The fix is the one that stopped t1nk33r.nook crashing on rebuild: reach the
  // engine through `owner`, captured at construction, never through the `root`
  // id lookup, and check it is still callable before every call.
  property bool tearingDown: false
  Component.onDestruction: tearingDown = true

  Process {
    id: depsProbe
    readonly property var owner: root
    command: ["bash", root.pluginDir + "/scripts/dependencies.sh", "--json"]
    running: false
    stdout: StdioCollector { id: depsOutput; waitForEnd: true }
    onExited: function(code) {
      if (!owner || owner.tearingDown || typeof owner.noteDependencies !== "function") return
      owner.noteDependencies(String(depsOutput.text || ""))
    }
  }

  Process {
    id: scanner
    readonly property var owner: root
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
      if (!owner || owner.tearingDown || typeof owner.noteScannerNeverLaunched !== "function") return
      owner.noteScannerNeverLaunched()
    }
    onExited: function(code) {
      if (!owner || owner.tearingDown || typeof owner.noteScanFinished !== "function") return
      owner.noteScanFinished(code, String(scanOutput.text || ""))
    }
  }
  function noteScannerNeverLaunched() {
    scanning = false
    available = false
    errorText = "The Quick Share CLI is not installed."
  }
  function noteScanFinished(code, payload) {
    scanning = false
    if (code === 0) {
      noteDevices(payload)
      statusText = devices.length ? "Ready" : "No devices nearby"
      return
    }
    errorText = "Quick Share could not search for devices."
    statusText = errorText
  }

  Process {
    id: sender
    readonly property var owner: root
    property bool launched: false
    // --to is mandatory off a TTY, and `qs` exits 2 rather than prompting if
    // it is missing. The device id is passed rather than the name: a name
    // match is a substring search and two phones can share one.
    //
    // The option goes before the paths and `--` ends the option list, so a
    // selected path is never read as a flag -- checked against the pinned
    // binary: `send -weird-file ...` is rejected as an unknown argument, the
    // same path after `--` is taken as a file. The order is not free: clap
    // treats everything after `--` as a positional, so putting `--to` there
    // would send the device id as a file name and fail with "not a TTY".
    command: {
      var argv = [root.binary, "--port", String(root.port)]
      if (root.advertisedName !== "") { argv.push("--name"); argv.push(root.advertisedName) }
      argv.push("send")
      argv.push("--to")
      argv.push(root.selectedDevice ? String(root.selectedDevice.id) : "")
      argv.push("--")
      for (var i = 0; i < root.pendingPaths.length; i++) argv.push(String(root.pendingPaths[i]))
      return argv
    }
    running: false
    stderr: SplitParser {
      readonly property var owner: root
      onRead: function(line) {
        if (!owner || owner.tearingDown || typeof owner.noteSendLine !== "function") return
        owner.noteSendLine(line)
      }
    }
    onStarted: sender.launched = true
    onRunningChanged: {
      if (running || sender.launched) return
      if (!owner || owner.tearingDown || typeof owner.noteSenderNeverLaunched !== "function") return
      owner.noteSenderNeverLaunched()
    }
    onExited: function(code) {
      if (!owner || owner.tearingDown || typeof owner.finishSend !== "function") return
      owner.finishSend(code)
    }
  }
  function noteSenderNeverLaunched() {
    pendingPaths = []
    failWith("The Quick Share CLI is not installed.")
  }

  Component.onCompleted: refreshDependencies()
}
