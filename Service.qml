import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// One Nearby engine per shell session, not one per monitor.
//
// The bar instantiates its widgets once per screen (Variants over
// Quickshell.screens), so a helper owned by the widget was started once per
// monitor. The helper binds the LocalSend port, so on a second monitor every
// instance after the first lost the race and exited with EADDRINUSE, leaving
// that bar reporting a receiver that could not start while another copy held
// the port. Registering the IPC target that many times had the same problem:
// only the first registration was used.
//
// The shell loads a `service` kind exactly once, so the helper, the transfer
// state, and the IPC target live here. Every bar widget is a view onto this
// object and owns nothing but its own cursor and popup.
Item {
  id: root

  // Injected by the shell when the service is created.
  property var shell: null
  property var manifest: null
  property string omarchyPath: Quickshell.env("OMARCHY_PATH") || ""

  readonly property string manifestPluginId: "t1nk33r.nearby-share"
  readonly property string metadataSourceDir: manifest && manifest.__sourceDir
    ? String(manifest.__sourceDir)
    : ""
  readonly property string pluginDir: metadataSourceDir !== ""
    ? metadataSourceDir
    : (Quickshell.env("HOME") || "") + "/.config/omarchy/plugins/" + manifestPluginId

  // Settings come from shell.json, not from the widgets.
  //
  // A widget cannot be the source here. The bar builds one per monitor and
  // injects `settings` a tick after the widget is created, so the first thing
  // a widget can report is the default rather than the persisted value, and
  // the rest are copies of the same entry. Reading the entry directly means
  // the persisted state and the effective state are the same value, so they
  // cannot drift apart, and `receiverConfigured` is a fact about the config
  // rather than about which widget spoke first.
  //
  // Read from the file, not from the API. `shell` here is
  // services/PluginShellApi.qml, which has no shellConfig: an installed
  // third-party plugin gets `barConfig`, a deep copy of shellConfig.bar
  // (shell.qml:326 publicBarConfig). Two things are missing from it, and both
  // are load-bearing:
  //
  //   * plugins[]. updateEntryInline() falls back to the plugins[] marker
  //     whenever the id is not a top-level bar.layout object entry -- a widget
  //     a drawer hosts, a bare string entry, or a plugin enabled without being
  //     placed on the bar. Reading only barConfig would not see what it wrote.
  //   * which document it came from. barConfig is populated before the user's
  //     shell.json is parsed, out of /usr/share/omarchy/config/omarchy/shell.json,
  //     so a bare marker there would read as "receiver on by default" and bind
  //     the LocalSend port for a user who had turned receiving off.
  //
  // One document, read once per change, is also one consistent answer: a split
  // between barConfig and a disk read could disagree mid-write. Writes still go
  // through the sanctioned API (updateEntryInline), and barConfig is what tells
  // this file to re-read -- see shellConfigFile.
  property var shellConfigDocument: null
  readonly property var configEntry: Model.barEntry(shellConfigDocument, manifestPluginId)
  readonly property bool receiverConfigured: configEntry !== null
  // Where a settings write lands: layout | plugins | items, or "" before the
  // config has been read. Reported by the status IPC because the difference
  // between "off" and "never resolved" is otherwise invisible from outside.
  readonly property string settingsSource: configEntry ? String(configEntry.source) : ""
  readonly property bool settingsWritable: Model.entryWritable(configEntry)
  readonly property bool receiverEnabled: Model.receiverEnabledIn(configEntry)
  // Which of the two panes is showing. Read from the same config entry as
  // receiverEnabled so the persisted value and the effective value cannot
  // drift, and so the choice survives a shell restart.
  readonly property string mode: Model.modeIn(configEntry)
  readonly property bool quickShareMode: mode === "quickshare"
  readonly property var quickshare: quickShareEngine
  // The name this machine advertises. Three sources; only the mode and the
  // custom string are persisted, because hostname and generated are derived.
  readonly property string deviceNameMode: Model.deviceNameModeIn(configEntry)
  readonly property string customDeviceName: Model.customDeviceNameIn(configEntry)
  // One generated name, computed once. Panel.qml recomputing this locally
  // produced a button that showed a different name than the machine actually
  // advertised, and the bar builds one Panel per monitor, so a machine-wide
  // value does not belong there.
  //
  // Seeded from the hostname, not the fingerprint: the fingerprint only arrives
  // on the helper's ready event, so seeding from it changed the name after the
  // helper had already launched and forced a spurious bounce every session.
  readonly property string generatedName: Model.generatedDeviceName(systemHostname !== "" ? systemHostname : "nearby")
  readonly property string advertisedName: Model.resolveDeviceName(configEntry, systemHostname, systemHostname !== "" ? systemHostname : "nearby")
  property string systemHostname: ""
  property string helperFingerprint: ""
  // Set while a rename is bouncing the helper, so the shutdown handler knows
  // not to turn the receiver off on the way through.
  property bool restartingForName: false
  property int nameRestartDeferrals: 0
  // A rename tears the helper down, which drops whatever it was carrying. The
  // shutdown clears the queues, so by the time anything could notice the
  // transfer is already gone -- the check has to happen before the shutdown is
  // sent, not after.
  readonly property bool transferInFlight: viewState === "sending" || viewState === "receiving"
    || viewState === "incoming" || viewState === "pin"
    || incomingQueue.length > 0 || pendingOutgoing !== null
    || activeIncomingSession !== "" || outgoingTransferId !== ""

  property string pluginVersion: ""
  property string minHelperVersion: ""
  // The version the helper has to reach. A manifest that does not declare a
  // floor is read as requiring the version it ships with, which is the rule
  // this plugin followed before the field existed.
  readonly property string requiredHelperVersion: minHelperVersion !== "" ? minHelperVersion : pluginVersion
  property string helperVersion: ""
  property bool backendReady: false
  property bool discoveryActive: false
  property var devices: []
  property var selectedDevice: null
  property string viewState: "nearby"
  property string statusText: "Starting receiver…"
  property string errorText: ""
  property var incomingQueue: []
  readonly property var incoming: Model.currentIncoming(incomingQueue)
  property string incomingText: ""
  property bool incomingTextPending: false
  property string lastReceivedPath: ""
  property real progress: 0
  property string transferName: ""
  property string transferPeer: ""
  property string activeIncomingSession: ""
  property string outgoingTransferId: ""
  property var pendingOutgoing: null
  property string pinError: ""
  property bool incomingPinEnabled: false
  property bool incomingPinUpdating: false
  property var pendingIncomingPinEnabled: null
  property string incomingPinError: ""
  property int transferSequence: 0
  property bool shutdownPending: false
  property bool backendAcceptedThisRun: false
  property bool backendVersionMismatch: false
  property string backendStartupFailureCode: ""
  property int backendStartupFailurePort: 0

  // The checkout selects immutable helper bytes in helper-release.env. The
  // launcher keeps those bytes outside the watched plugin tree and can repair
  // a missing or incompatible cached helper through the action below.
  property bool helperMissing: false
  property bool helperUpdating: false
  property bool helperUpdateInstalled: false
  property string helperUpdateStatus: ""
  property string helperUpdateError: ""
  // Plugin and helper versions have independent release cycles. A compatible
  // helper is not "behind" merely because the plugin version is higher.
  readonly property bool helperUpdateOffered: pluginVersion !== ""
    && (backendVersionMismatch || helperMissing)
  readonly property int maxOutgoingTextBytes: 1024 * 1024
  // One line, and the only place the versions are stated. The hero shows the
  // short status and the panel shows this; saying it in both is what made the
  // popup repeat itself three times over four lines.
  readonly property string helperUpdateDetail: !helperUpdateOffered
    ? ""
    : (helperMissing
      ? "The helper binary is missing."
      : "Needs helper " + requiredHelperVersion + " · installed "
        + (helperVersion !== "" ? helperVersion : "unknown"))

  // Discovery follows the popup, and the popup exists once per monitor, so
  // openness is a count rather than a flag: discovery runs while any view is
  // open and stops when the last one closes.
  property int openViewCount: 0
  readonly property bool anyViewOpen: openViewCount > 0
  readonly property bool backendRunning: backend.running

  // Views own their cursor and their PIN field; the engine only asks. A single
  // engine driving several popups cannot reach into any one of them.
  signal cursorRequested(int index)
  signal pinCleared()
  signal pinFocusRequested()
  signal incomingPinCleared()
  signal incomingPinFocusRequested()
  signal customNameFocusRequested()
  signal focusRestoreRequested()

  // Set before anything else is torn down. A shell.json write rebuilds the
  // plugin tree, so this object is destroyed and rebuilt routinely, not only at
  // shutdown, and a subprocess or a file load in flight outlives it. Its
  // handlers are the child's own code and still run, but the parent they call
  // into is already gone: QObjectPrivate::deleteChildren runs after the
  // parent's QML metaobject is destroyed, so `root.anything()` throws a
  // TypeError right inside the destruction path. Every such handler below
  // reaches the engine through `owner`, captured at construction, and checks it
  // is still callable first. This is the QuickShare.qml:172 crash, in the two
  // files that have the shape.
  property bool tearingDown: false
  Component.onDestruction: tearingDown = true

  // /proc, not `hostname` -- no subprocess, and it is always readable.
  FileView {
    readonly property var owner: root
    path: "/proc/sys/kernel/hostname"
    printErrors: false
    // Sanitised here, not at the render site: this value is concatenated into a
    // kit Button label, and the kit renders labels with Qt's default AutoText.
    // displayName is idempotent, so resolveDeviceName applying it again is safe.
    onLoaded: {
      if (!owner || owner.tearingDown || typeof owner.noteHostname !== "function") return
      owner.noteHostname(text())
    }
    onLoadFailed: {
      if (!owner || owner.tearingDown || typeof owner.noteHostname !== "function") return
      owner.noteHostname("")
    }
  }
  function noteHostname(raw) { root.systemHostname = Model.displayName(String(raw || ""), 64) }

  FileView {
    readonly property var owner: root
    path: root.pluginDir + "/manifest.json"
    printErrors: false
    onLoaded: {
      if (!owner || owner.tearingDown || typeof owner.noteManifest !== "function") return
      owner.noteManifest(text())
    }
    onLoadFailed: {
      if (!owner || owner.tearingDown || typeof owner.noteManifest !== "function") return
      owner.noteManifest("")
    }
  }
  function noteManifest(raw) {
    root.pluginVersion = Model.manifestVersion(raw, root.manifestPluginId)
    root.minHelperVersion = Model.manifestMinHelperVersion(raw, root.manifestPluginId)
    if (root.pluginVersion !== "") return
    root.errorText = "Nearby manifest version unavailable."
    root.statusText = root.errorText
  }

  // The settings document. Read-only, and event-driven rather than polled:
  // watchChanges covers an edit by anything else (the settings plugin, a hand
  // edit, `omarchy plugin`), and the barConfig connection below covers this
  // plugin's own write without waiting on inotify.
  readonly property string shellConfigPath: (Quickshell.env("HOME") || "") + "/.config/omarchy/shell.json"
  FileView {
    id: shellConfigFile
    readonly property var owner: root
    path: root.shellConfigPath
    watchChanges: true
    printErrors: false
    onLoaded: {
      if (!owner || owner.tearingDown || typeof owner.noteShellConfig !== "function") return
      owner.noteShellConfig(text())
    }
    onLoadFailed: {
      if (!owner || owner.tearingDown || typeof owner.noteShellConfig !== "function") return
      owner.noteShellConfig("")
    }
    onFileChanged: reload()
  }

  // The host rewrites shell.json through updateEntryInline and re-pushes
  // barConfig in the same pass (shell.qml:879, syncPluginApis), so a barConfig
  // change is the in-process signal that the file on disk has moved.
  Connections {
    target: root.shell
    ignoreUnknownSignals: true
    function onBarConfigChanged() { shellConfigFile.reload() }
  }

  // Named so it can be cleared without wiping an unrelated failure: the
  // manifest read reports through the same two properties.
  readonly property string shellConfigErrorText: "Nearby cannot read "
    + shellConfigPath + ", so its settings are unavailable."

  function noteShellConfig(raw) {
    var parsed = Model.shellConfigIn(raw)
    if (parsed === null) {
      // A read that lands inside the host's atomic replace must not stop a
      // running receiver, so the last good document stands.
      if (root.shellConfigDocument !== null) {
        console.warn("nearby: shell.json unreadable, keeping the settings already read")
        return
      }
      root.errorText = root.shellConfigErrorText
      root.statusText = root.errorText
      return
    }
    if (root.errorText === root.shellConfigErrorText) {
      root.errorText = ""
      root.statusText = "Starting receiver\u2026"
    }
    root.shellConfigDocument = parsed
  }

  // Registered once, from the one object there is one of. Registering this
  // from the widget meant one handler per monitor, of which the shell kept the
  // first and warned about the rest.
  //
  // Opening a popup is still the widget's job, so those calls are handed back
  // to the shell, which routes them through the bar to the focused monitor
  // rather than to whichever instance had claimed the target.
  function summonView(action) {
    if (!shell || typeof shell[action] !== "function") return "unknown"
    return shell[action](manifestPluginId, "{}") === false ? "unknown" : "ok"
  }

  IpcHandler {
    target: "t1nk33r.nearby-share"
    function open(): string { return root.summonView("summon") }
    function close(): string { return root.summonView("hide") }
    function toggle(): string { return root.summonView("toggle") }
    function receiverOn(): string { if (!root.receiverEnabled) root.toggleReceiver(); return "ok" }
    function receiverOff(): string { if (root.receiverEnabled) root.toggleReceiver(); return "ok" }
    function receiverToggle(): string { root.toggleReceiver(); return "ok" }
    // The pane switch, for a keybinding or a script. `mode` with no argument
    // reports; the two named methods select.
    function name(): string { return root.advertisedName }
    function mode(): string { return root.mode }
    function localsend(): string { root.setMode("localsend"); return "ok" }
    function quickshare(): string { root.setMode("quickshare"); return "ok" }
    // Quick Share has no resident process to ask, so this reports what the
    // last dependency probe found rather than a live connection.
    function quickshareStatus(): string {
      return JSON.stringify({available:quickShareEngine.available,checked:quickShareEngine.depsChecked,
        missing:quickShareEngine.missingDeps,devices:quickShareEngine.devices.length,state:quickShareEngine.viewState})
    }
    // The same repair the panel button runs, for a shell whose bar is not
    // where the user is looking when the helper stops matching.
    function retryHelper(): string { if (root.helperUpdating) return "busy"; root.startHelperUpdate(); return "ok" }
    // The helper version and the floor it has to clear are reported here
    // because a mismatch otherwise shows up only as a panel that says it is
    // not ready, which is the same thing a port conflict looks like.
    //
    // `configured` is reported beside `enabled` because they are two different
    // failures that used to look identical from here: on 4.0.3 this plugin read
    // its settings from shell.shellConfig, which the third-party API does not
    // have, so the entry never resolved and the receiver reported itself off
    // while shell.json said receiverEnabled true.
    function status(): string { return JSON.stringify({enabled:root.receiverEnabled,configured:root.receiverConfigured,source:root.settingsSource,writable:root.settingsWritable,ready:root.backendReady,running:backend.running,devices:root.devices.length,helper:root.helperVersion,requires:root.requiredHelperVersion,updateOffered:root.helperUpdateOffered}) }
    // What the host actually handed this plugin, for the next time settings do
    // not stick. `shellConfig` is the property the plugin used to read and the
    // one the API does not carry; `barConfigKeys` is what it carries instead.
    function configProbe(): string {
      var api = root.shell
      return JSON.stringify({
        haveShell: !!api,
        shellConfig: typeof (api ? api.shellConfig : undefined),
        barConfigKeys: api && api.barConfig ? Object.keys(api.barConfig).sort() : [],
        barConfigHasPlugins: !!(api && api.barConfig && api.barConfig.plugins),
        // Reported as a type only, never called: shell.qml:162
        // mutateShellConfig() persists unconditionally, with no dirty check, so
        // even a no-op mutator would rewrite shell.json. It returns false for
        // this plugin regardless -- shell.qml:654 only wires it up for a
        // manifest declaring the `bar` kind, and this one declares
        // service + bar-widget.
        mutateShellConfig: api ? typeof api.mutateShellConfig : "undefined",
        updateEntryInline: api ? typeof api.updateEntryInline : "undefined",
        configPath: root.shellConfigPath,
        configRead: root.shellConfigDocument !== null,
        entry: root.configEntry,
        source: root.settingsSource,
        writable: root.settingsWritable
      })
    }
  }

  function viewOpened() {
    openViewCount++
    if (openViewCount !== 1) return
    if (quickShareMode) {
      // Quick Share is disabled on this machine -- QuickShare.qml's Process
      // blocks are commented out, so there is nothing to probe and nothing to
      // scan. The branch still returns: a Quick Share popup must not fall
      // through to LocalSend discovery.
      // quickShareEngine.refreshDependencies()
      // if (quickShareEngine.available && quickShareEngine.viewState === "nearby") quickShareEngine.scan()
      return
    }
    if (viewState === "nearby" && receiverEnabled && backendReady) startDiscovery()
  }
  function viewClosed() {
    if (openViewCount > 0) openViewCount--
    if (openViewCount === 0) stopDiscovery()
  }

  // A desktop notification exists to reach a user who is not looking at the
  // panel. Raising one for something the open panel is already showing is a
  // duplicate the user has to dismiss on top of the prompt they are answering.
  //
  // Open is not enough on its own: an arrival during a transfer, a PIN prompt,
  // or behind an earlier queued request is held back rather than displayed, so
  // the panel being open would otherwise swallow it silently. The caller says
  // whether this particular event reached the screen.
  function notificationNeeded(onScreen) {
    return !anyViewOpen || !onScreen
  }

  function send(command) {
    if (!backend.running) return
    backend.write(JSON.stringify(command) + "\n")
  }
  function utf8ByteLength(value) {
    var text=String(value || "")
    var bytes=0
    for (var index=0; index<text.length; index++) {
      var code=text.charCodeAt(index)
      if (code<=0x7f) bytes++
      else if (code<=0x7ff) bytes+=2
      else if (code>=0xd800 && code<=0xdbff && index+1<text.length
               && text.charCodeAt(index+1)>=0xdc00 && text.charCodeAt(index+1)<=0xdfff) {
        bytes+=4
        index++
      } else bytes+=3
    }
    return bytes
  }
  function bindBackendRunning() {
    // Assigning a plain `true` here removes the declarative binding from
    // Process.running. Reinstall the binding instead so receiver OFF -> ON can
    // still start the helper after the retry budget has been exhausted.
    backend.running = Qt.binding(function() {
      return root.receiverConfigured && root.receiverEnabled && root.pluginVersion !== ""
    })
  }
  // One writer. `shell.updateEntryInline(id, settings)` is the sanctioned
  // per-entry writer on services/PluginShellApi.qml, and for a plugin's own id
  // shell.qml:648 routes it straight to shell.qml:1078 updateEntryInline(),
  // which replaces the whole entry with `{id, ...settings}` -- so every key the
  // target already held has to be resent or it is dropped.
  //
  // targetSettings, not the merged view: the keys resent are the write target's
  // own, so a value inherited from a drawer's items[] entry is never copied
  // onto the plugins[] marker that shadows it.
  //
  // shell.mutateShellConfig() is not an option and no longer attempted.
  // shell.qml:654 only wires it up for a manifest declaring the `bar` kind;
  // this plugin is service + bar-widget, so it returned false on every call and
  // the string-entry promotion path it guarded never ran. Nothing is lost: a
  // bare string in bar.layout is not a write target for the host either, so the
  // settings land on the plugins[] marker and Model.barEntry reads them back
  // from there without rewriting the user's layout.
  function persistSettings(patch) {
    if (!shell || typeof shell.updateEntryInline !== "function") return false
    if (!receiverConfigured) return false
    var settings = Object.assign({}, configEntry.targetSettings, patch)
    if (!settingsWritable) {
      // Hosted inside a drawer with no plugins[] marker beside it. The host
      // writes bar.layout's top level and plugins[], never a drawer's items,
      // so there is nowhere for this to go and saying so beats a control that
      // silently springs back.
      console.warn("nearby: no writable shell.json entry for " + manifestPluginId
        + " (hosted at " + settingsSource + "), settings cannot be saved")
      errorText = "Nearby cannot save its settings: its shell.json entry is not one the shell writes."
      statusText = errorText
      return false
    }
    // Idempotent by the host's own comparison: an unchanged entry is not
    // rewritten and returns false.
    return shell.updateEntryInline(manifestPluginId, settings) === true
  }
  // receiverEnabled follows the entry, so writing the entry is what turns the
  // receiver on or off. There is no second copy of the state to keep in step.
  function persistReceiverEnabled(enabled) { return persistSettings({ receiverEnabled: enabled }) }
  function persistMode(next) { return persistSettings({ mode: next }) }
  // Switching panes abandons neither transfer: the LocalSend helper keeps
  // receiving while the Quick Share pane is showing, and a `qs send` in flight
  // survives a switch back. Only the cursor and the per-pane target reset.
  function persistDeviceName(mode, custom) {
    var wanted = (mode === "hostname" || mode === "generated" || mode === "custom") ? mode : "hostname"
    return persistSettings({ deviceNameMode: wanted, deviceName: String(custom || "") })
  }
  function chooseNameMode(mode) { persistDeviceName(mode, customDeviceName) }
  function submitCustomName(text) {
    var next = Model.displayName(text, 32)
    // An empty submission used to persist "", which resolveDeviceName then
    // ignores in favour of the hostname -- so a stray Enter silently discarded
    // the name with no confirmation.
    if (next === "") return
    persistDeviceName("custom", next)
  }
  function requestCustomNameFocus() {
    if (deviceNameMode !== "custom") persistDeviceName("custom", customDeviceName)
    customNameFocusRequested()
  }
  function openDeviceName() { viewState = "device_name"; cursorRequested(0) }
  function closeDeviceName() {
    viewState = "nearby"
    cursorRequested(0)
    focusRestoreRequested()
    // A rename bounces the helper, and the post-restart `ready` skips discovery
    // because the user is still sitting in this pane -- so returning to the
    // device list showed "No devices nearby" with discovery switched off.
    if (anyViewOpen && receiverEnabled && backendReady) startDiscovery()
  }

  // The helper reads its alias once, at startup, so a rename means bouncing it.
  // Debounced because a custom name is typed one character at a time and the
  // port would otherwise be bound and unbound per keystroke.
  onAdvertisedNameChanged: {
    if (!receiverEnabled || !backend.running || shutdownPending) return
    nameRestartDeferrals = 0
    nameRestart.restart()
  }
  function restartForName() {
    if (!receiverEnabled || shutdownPending || !backend.running) return
    if (transferInFlight) {
      // Wait for the transfer rather than killing it. Bounded so a wedged
      // session cannot postpone the rename forever; past the budget the rename
      // is abandoned rather than forced, because losing a transfer is worse
      // than advertising the old name until the next restart.
      if (nameRestartDeferrals >= 30) { nameRestartDeferrals = 0; return }
      nameRestartDeferrals++
      nameRestart.restart()
      return
    }
    nameRestartDeferrals = 0
    restartingForName = true
    shutdownPending = true
    statusText = "Applying new name\u2026"
    send({command:"shutdown"})
    nameShutdownFallback.restart()
  }
  // Not receiverShutdownFallback. Its 250 ms is safe for toggleReceiver, where
  // firing early still takes the helper down because the running binding breaks.
  // On a rename receiverEnabled stays true, so an early fire would clear the
  // flags while the helper is still up and hand its real exit to the
  // unexpected-stop path.
  function finishNameShutdown() {
    if (!restartingForName) return
    if (backend.running) { nameShutdownFallback.restart(); return }
    finishReceiverShutdown()
  }

  function setMode(next) {
    var wanted = next === "quickshare" ? "quickshare" : "localsend"
    if (wanted === mode) return
    persistMode(wanted)
    cursorRequested(0)
    if (wanted === "quickshare") {
      // Disabled on this machine: the probe and the scan are commented out in
      // QuickShare.qml, so switching to the pane starts nothing.
      // quickShareEngine.refreshDependencies()
      // if (anyViewOpen && quickShareEngine.available) quickShareEngine.scan()
    }
  }

  function toggleReceiver() {
    if (shutdownPending) return
    var enable = !receiverEnabled
    backendRestart.stop()
    if (enable) {
      backendRestart.attempts = 0
      persistReceiverEnabled(true)
      errorText = ""
      statusText = "Starting receiver…"
    } else {
      stopDiscovery()
      shutdownPending = true
      send({command:"shutdown"})
      receiverShutdownFallback.restart()
    }
  }
  function finishReceiverShutdown() {
    receiverShutdownFallback.stop()
    shutdownPending = false
    // A rename bounces the helper through this same path. Persisting `false`
    // here would turn receiving off as a side effect of renaming, which the
    // user would only discover when a transfer failed.
    if (restartingForName) {
      restartingForName = false
      backendReady = false
      devices = []
      // The shutdown cleared the queues, so a transfer view left standing shows
      // a frozen progress bar with no route out -- goBack closes the popup for
      // those states and the post-restart ready does not touch viewState.
      if (viewState !== "device_name" && viewState !== "nearby") {
        viewState = "nearby"
        cursorRequested(0)
      }
      selectedDevice = null
      statusText = "Starting receiver\u2026"
      errorText = ""
      if (!backend.running) bindBackendRunning()
      return
    }
    persistReceiverEnabled(false)
    backendReady = false
    devices = []
    selectedDevice = null
    incomingQueue = []
    incomingTextPending = false
    activeIncomingSession = ""
    clearPendingOutgoing()
    viewState = "nearby"
    statusText = "Turned off"
    errorText = ""
  }
  function startDiscovery() { discoveryActive = true; errorText = ""; statusText = devices.length ? "Ready" : "Looking nearby…"; send({command:"discovery_start"}) }
  function forceFullDiscovery() { discoveryActive = true; errorText = ""; statusText = "Scanning local network…"; send({command:"discovery_start",force_full:true}) }
  function stopDiscovery() { discoveryActive = false; send({command:"discovery_stop"}) }
  function chooseDevice(index) { if (index >= 0 && index < devices.length) { selectedDevice = devices[index]; viewState = "target"; cursorRequested(0) } }
  function clearTarget() { viewState = "nearby"; selectedDevice = null; cursorRequested(0) }
  function openIncomingPinSettings() { if(!backendReady)return; incomingPinError=""; viewState="incoming_pin_settings"; cursorRequested(0) }
  function beginIncomingPinEdit() { if(incomingPinUpdating||!backendReady)return; incomingPinError=""; viewState="incoming_pin_edit"; incomingPinCleared(); incomingPinFocusRequested() }
  function requestDisableIncomingPin() { if(incomingPinUpdating||!backendReady||!incomingPinEnabled)return; incomingPinError=""; viewState="incoming_pin_disable"; cursorRequested(0) }
  function cancelIncomingPinSettings() {
    if(incomingPinUpdating)return
    incomingPinError=""; incomingPinCleared()
    if(viewState==="incoming_pin_edit"||viewState==="incoming_pin_disable"){viewState="incoming_pin_settings";cursorRequested(0)}
    else{viewState="nearby";cursorRequested(0);focusRestoreRequested()}
  }
  function submitIncomingPin(pin) {
    if(incomingPinUpdating||!backendReady)return
    var entered=String(pin || "")
    if(!/^[A-Za-z0-9._~-]{1,64}$/.test(entered)){incomingPinError="Use 1–64 letters, numbers, dot, underscore, tilde or hyphen";incomingPinFocusRequested();return}
    incomingPinUpdating=true; pendingIncomingPinEnabled=true; incomingPinError=""
    send({command:"set_incoming_pin",pin:entered})
  }
  function confirmDisableIncomingPin() {
    if(incomingPinUpdating||!backendReady||!incomingPinEnabled)return
    incomingPinUpdating=true; pendingIncomingPinEnabled=false; incomingPinError=""
    send({command:"disable_incoming_pin"})
  }
  // Source updates and helper releases are independent. The repair command asks the
  // launcher to prefetch the immutable helper selected by this checkout.
  function startHelperUpdate() {
    if (helperUpdating || pluginVersion === "" || helperUpdater.running) return
    helperUpdateError=""
    helperUpdateStatus="Contacting GitHub…"
    helperUpdateInstalled=false
    helperUpdating=true
    helperUpdater.launched=false
    helperUpdater.running=true
  }
  function handleUpdaterEvent(event) {
    if (!event || !event.event) return
    if (event.event === "step") helperUpdateStatus=String(event.message || "")
    else if (event.event === "done") { helperUpdateStatus=""; helperUpdateError=""; helperUpdateInstalled=true }
    else if (event.event === "failed") { helperUpdateStatus=""; helperUpdateError=String(event.message || "") }
  }
  function finishHelperUpdate(code) {
    helperUpdating=false
    helperUpdateStatus=""
    // The repair command reports success only after the cached helper verifies.
    if (code !== 0 && !helperUpdateInstalled) {
      if (helperUpdateError === "") helperUpdateError="Nearby could not update the helper."
      return
    }
    helperUpdateError=""
    helperMissing=false
    helperVersion=""
    backendVersionMismatch=false
    backendStartupFailureCode=""
    backendStartupFailurePort=0
    backendRestart.stop()
    backendRestart.attempts=0
    errorText=""
    statusText="Starting receiver…"
    // The mismatch shutdown left Process.running written rather than bound, so
    // the binding has to be restored before the new helper can start. Same
    // reason backendRestart calls this instead of assigning true.
    if (!backend.running) bindBackendRunning()
  }
  // The hero gets a short status and the body gets the detail. Assigning one
  // sentence to both is what cropped it: the hero line is uppercased and
  // letterspaced, so anything longer than a few words ends in an ellipsis
  // partway through a word and tells the user less than the icon already did.
  function reportFailure(summary, detail) { statusText=summary; errorText=detail }
  function failWith(message) { viewState="error"; errorText=message; statusText=errorText }
  function cancelOutgoing() { send({command:"cancel_outgoing",transfer_id:outgoingTransferId}) }
  function noteTextCopied() { if (viewState !== "text") return; viewState="success"; statusText="Received" }
  function clearPendingOutgoing() { pendingOutgoing=null; outgoingTransferId=""; pinError=""; pinCleared() }
  function dispatchPendingOutgoing(pin) {
    if (!pendingOutgoing) return
    transferSequence++
    outgoingTransferId="out-"+Date.now()+"-"+transferSequence
    var command=Model.outgoingCommand(pendingOutgoing,outgoingTransferId,pin)
    if (!command) { clearPendingOutgoing(); viewState="error"; errorText="Transfer failed"; return }
    pinCleared()
    pinError=""
    send(command)
  }
  function beginOutgoing(pending) {
    if(pendingOutgoing||!backend.running)return
    if(pending && pending.kind==="text" && utf8ByteLength(pending.text)>maxOutgoingTextBytes) {
      failWith("Text is too large (maximum 1 MiB)")
      return
    }
    pendingOutgoing=pending
    dispatchPendingOutgoing(null)
  }
  function retryWithPin(pin) {
    if (outgoingTransferId !== "") return
    var entered=String(pin || "")
    if (entered === "") { pinError="Enter the receiver PIN"; pinFocusRequested(); return }
    dispatchPendingOutgoing(entered)
  }
  function showPinPrompt(message) {
    outgoingTransferId=""
    viewState="pin"
    pinError=message
    statusText="PIN required"
    pinFocusRequested()
  }
  function cancelPin() { if(outgoingTransferId!=="")send({command:"cancel_outgoing",transfer_id:outgoingTransferId}); clearPendingOutgoing(); if(incoming){viewState="incoming";cursorRequested(1)}else if(incomingTextPending){incomingTextPending=false;viewState="text";statusText="Text received";cursorRequested(0)}else{viewState=selectedDevice?"target":"nearby";cursorRequested(0)} focusRestoreRequested() }
  function acceptIncoming() { if (!incoming) return; send({command:"accept",request_id:incoming.requestId}); viewState="receiving"; transferPeer=incoming.sender; transferName=Model.incomingSummary(incoming.files); progress=0 }
  function declineIncoming() {
    if (!incoming) return
    var requestId = incoming.requestId
    send({command:"decline",request_id:requestId})
    incomingQueue = Model.removeIncoming(incomingQueue, requestId)
    if (!incoming&&incomingTextPending) { incomingTextPending=false; viewState="text"; statusText="Text received" }
    else { viewState = incoming ? "incoming" : "nearby"; statusText = incoming ? "Incoming transfer" : "Declined" }
    cursorRequested(incoming ? 1 : 0)
  }
  function finishIncoming(terminalState, message, completed) {
    activeIncomingSession = ""
    if (pendingOutgoing) return
    if (incoming) {
      viewState = "incoming"
      cursorRequested(1)
      statusText = "Incoming transfer"
      errorText = ""
      progress = 0
      return
    }
    if (incomingTextPending) { incomingTextPending=false; viewState="text"; statusText="Text received"; errorText=""; progress=0; return }
    viewState = terminalState
    statusText = message
    errorText = terminalState === "error" ? message : ""
    if (completed) progress = 1
  }
  function finishOutgoing(terminalState, message, completed) {
    clearPendingOutgoing()
    if (incoming) {
      viewState = Model.viewAfterOutgoing(true, terminalState)
      cursorRequested(1)
      statusText = "Incoming transfer"
      errorText = ""
      progress = 0
      return
    }
    if (incomingTextPending) { incomingTextPending=false; viewState="text"; statusText="Text received"; errorText=""; progress=0; return }
    viewState = Model.viewAfterOutgoing(false, terminalState)
    statusText = message
    errorText = terminalState === "error" ? message : ""
    if (completed) progress = 1
  }
  function finishText() { incomingText=""; incomingTextPending=false; viewState="nearby"; cursorRequested(0); startDiscovery() }
  function finishTerminal() { viewState="nearby"; cursorRequested(0); startDiscovery() }
  function handleBackendExit(code) {
    backendReady=false; discoveryActive=false; incomingQueue=[]; incomingTextPending=false; activeIncomingSession=""; incomingPinUpdating=false; pendingIncomingPinEnabled=null; incomingPinError=""; incomingPinCleared(); clearPendingOutgoing()
    if (shutdownPending) { finishReceiverShutdown(); return }
    if (!receiverEnabled) { statusText="Turned off"; errorText=""; return }
    if (backendVersionMismatch) return
    if (!backendAcceptedThisRun) {
      // An early exit alone does not identify its cause. The helper reports a
      // confirmed bind conflict as a structured event before it exits; all
      // other pre-ready failures remain generic. Both keep the existing
      // bounded retry schedule so a transient conflict can recover.
      if (backendStartupFailureCode === "receiver_security_settings_invalid") {
        reportFailure("Security settings invalid",
          "Nearby security settings are invalid. Repair or remove Nearby's settings.json in your XDG state directory.")
      } else if (backendRestart.attempts < 4) {
        reportFailure("Retrying…", "Nearby receiver could not start. Retrying…")
      } else if (backendStartupFailureCode === "receiver_port_in_use") {
        var port = backendStartupFailurePort > 0 ? backendStartupFailurePort : 53317
        reportFailure("Port " + port + " in use",
          "LocalSend receiver port " + port + " is already in use. Another LocalSend receiver on this computer may be running. Quit it and enable Nearby again.")
      } else {
        reportFailure("Could not start", "Nearby receiver could not start.")
      }
    } else {
      reportFailure(code===0 ? "Receiver stopped" : "Receiver unavailable",
        code===0 ? "Receiver stopped" : "Receiver unavailable")
      if (viewState.indexOf("incoming_pin_")===0) { viewState="error"; reportFailure("Backend stopped", "Nearby backend stopped while updating receiver security") }
      else if (viewState==="sending"||viewState==="receiving"||viewState==="pin"||viewState==="incoming") { viewState="error"; reportFailure("Backend stopped", "Nearby backend stopped during transfer") }
    }
    if (backendStartupFailureCode !== "receiver_security_settings_invalid" && backendRestart.attempts < 4) { backendRestart.attempts++; backendRestart.interval=Math.min(30000,1000*Math.pow(2,backendRestart.attempts-1)); backendRestart.restart() }
  }
  function handleEvent(event) {
    if (!event || !event.event) return
    if (backendVersionMismatch && event.event !== "ready") return
    if (event.event === "startup_failed") {
      backendStartupFailureCode=String(event.code || "")
      backendStartupFailurePort=Number(event.port) || 0
    }
    else if (event.event === "ready") {
      helperVersion=String(event.helperVersion || "")
      helperMissing=false
      if (!Model.helperSatisfies(requiredHelperVersion, helperVersion)) {
        backendReady=false
        backendVersionMismatch=true
        reportFailure("Helper out of date", helperUpdateDetail)
        send({command:"shutdown"})
        return
      }
      helperFingerprint=String(event.fingerprint || helperFingerprint); backendAcceptedThisRun=true; backendReady=true; backendVersionMismatch=false; backendRestart.attempts=0; statusText="Ready to receive"; errorText=""; if(anyViewOpen&&viewState==="nearby")startDiscovery()
    }
    else if (event.event === "incoming_pin_state") {
      incomingPinEnabled=event.enabled===true
      if(pendingIncomingPinEnabled!==null){var enabled=pendingIncomingPinEnabled===true;var settingsStillVisible=viewState.indexOf("incoming_pin_")===0;pendingIncomingPinEnabled=null;incomingPinUpdating=false;incomingPinError="";incomingPinCleared();if(settingsStillVisible){viewState="incoming_pin_settings";statusText=enabled?"Incoming PIN enabled":"Incoming PIN disabled";cursorRequested(0);focusRestoreRequested()}}
    }
    else if (event.event === "incoming_pin_update_failed") {
      pendingIncomingPinEnabled=null;incomingPinUpdating=false;incomingPinError=String(event.message||"Unable to update incoming PIN");incomingPinCleared();if(viewState==="incoming_pin_edit")incomingPinFocusRequested()
    }
    else if (event.event === "peer_snapshot") { devices=Model.snapshotDevices(event.devices); statusText=devices.length ? "Ready" : "Looking nearby…" }
    else if (event.event === "device") { devices=Model.upsertDevice(devices,event.device); statusText=devices.length ? "Ready" : "Looking nearby…" }
    else if (event.event === "discovery_started") discoveryActive=true
    else if (event.event === "discovery_stopped") discoveryActive=false
    else if (event.event === "incoming_request") {
      if(viewState.indexOf("incoming_pin_")===0){incomingPinError="";incomingPinCleared()}
      incomingQueue=Model.enqueueIncoming(incomingQueue,event); if(!incomingTextPending)incomingText=""
      var incomingTakesView = viewState!=="sending" && viewState!=="receiving" && viewState!=="pin"
      if (incomingTakesView) { viewState="incoming"; cursorRequested(1) }
      if (notificationNeeded(incomingTakesView && incoming && incoming.requestId===event.requestId))
        Quickshell.execDetached(["omarchy-notification-send","--app-name","Nearby","--urgency","normal","Incoming transfer",String(event.sender)+" wants to send "+Model.incomingSummary(event.files)])
    }
    else if (event.event === "incoming_text") {
      if(viewState.indexOf("incoming_pin_")===0){incomingPinError="";incomingPinCleared()}
      incomingText=String(event.text || ""); transferPeer=String(event.sender || ""); incomingTextPending=pendingOutgoing!==null; if (!pendingOutgoing) { viewState="text"; stopDiscovery() }
      if (notificationNeeded(!incomingTextPending))
        Quickshell.execDetached(["omarchy-notification-send","--app-name","Nearby","--urgency","normal","Text received","From "+String(event.sender || "")])
    }
    else if (event.event === "incoming_accepted") { incomingQueue=Model.removeIncoming(incomingQueue,event.requestId) }
    else if (event.event === "incoming_expired") {
      var expiredWasCurrent=incoming&&incoming.requestId===event.requestId
      incomingQueue=Model.removeIncoming(incomingQueue,event.requestId)
      if (expiredWasCurrent&&(viewState==="incoming"||(viewState==="receiving"&&activeIncomingSession===""))) {
        if (incoming) { statusText="Incoming transfer"; cursorRequested(1) }
        else if (incomingTextPending) { incomingTextPending=false; viewState="text"; statusText="Text received"; errorText="" }
        else { viewState="error"; errorText="Transfer request expired"; statusText=errorText }
      }
    }
    else if (event.event === "incoming_progress") { if(activeIncomingSession===""){if(viewState!=="receiving")return;activeIncomingSession=String(event.sessionId)} if(activeIncomingSession!==String(event.sessionId))return; if(pendingOutgoing)return; viewState="receiving"; transferName=String(event.name); transferPeer=String(event.sender); progress=event.total>0 ? event.bytes/event.total : 0 }
    else if (event.event === "file_received") { if(activeIncomingSession===""){if(viewState!=="receiving")return;activeIncomingSession=String(event.sessionId)} if(activeIncomingSession!==String(event.sessionId))return; lastReceivedPath=String(event.path); if(pendingOutgoing)return; transferName=String(event.name); transferPeer=String(event.sender) }
    else if (event.event === "incoming_done") { if(activeIncomingSession!==String(event.sessionId))return; finishIncoming("success","Received",true) }
    else if (event.event === "incoming_cancelled") { if(activeIncomingSession===""){if(viewState!=="receiving")return;activeIncomingSession=String(event.sessionId)} if(activeIncomingSession!==String(event.sessionId))return; finishIncoming("error","Transfer cancelled",false) }
    else if (event.event === "incoming_failed") { if(activeIncomingSession===""){if(viewState!=="receiving")return;activeIncomingSession=String(event.sessionId)} if(activeIncomingSession!==String(event.sessionId))return; finishIncoming("error",String(event.message||"Transfer failed"),false) }
    else if (event.event === "incoming_declined") { incomingQueue=Model.removeIncoming(incomingQueue,event.requestId) }
    else if (event.event === "outgoing_preparing") { if(String(event.transferId)!==outgoingTransferId)return; viewState="sending"; transferName=String(event.name); transferPeer=String(event.target); progress=0; stopDiscovery() }
    else if (event.event === "outgoing_progress") { if(String(event.transferId)!==outgoingTransferId)return; viewState="sending"; progress=event.total>0 ? event.bytes/event.total : 0 }
    else if (event.event === "outgoing_done") { if(String(event.transferId)!==outgoingTransferId)return; finishOutgoing("success", "Sent", true) }
    else if (event.event === "outgoing_cancelled") { if(String(event.transferId)!==outgoingTransferId)return; finishOutgoing("error", "Transfer cancelled", false) }
    else if (event.event === "outgoing_pin_required") { if(String(event.transferId)!==outgoingTransferId)return; showPinPrompt("") }
    else if (event.event === "outgoing_invalid_pin") { if(String(event.transferId)!==outgoingTransferId)return; showPinPrompt("Incorrect PIN") }
    else if (event.event === "outgoing_failed") { if(event.transferId && String(event.transferId)!==outgoingTransferId)return; finishOutgoing("error", String(event.message||"Transfer failed"), false) }
    else if (event.event === "error") { viewState="error"; errorText=String(event.message||"Transfer failed"); statusText=errorText }
  }

  // Every handler below reaches the engine through `owner` and checks it is
  // still callable: a helper's exit, a line of its output, or a launch failure
  // can all arrive after this object has been destroyed. See tearingDown.
  Process {
    id: backend
    readonly property var owner: root
    property bool launched: false
    command: [root.pluginDir + "/bin/nearby-helper-launcher"]
    // The helper takes its advertised alias from HOSTNAME at startup, and
    // HOSTNAME is a bash variable that is never exported -- so a GUI-launched
    // helper always fell back to a hardcoded string. Supplying it here fixes
    // the name without patching the helper, which stays identical to upstream.
    // Kept over upstream, which launches the helper with no environment: the
    // launcher has to pass HOSTNAME through to the cached helper it executes.
    environment: ({ "HOSTNAME": root.advertisedName })
    // Not eligible to start until shell.json has been read. Defaulting to on
    // before then would let the helper bind the LocalSend port and announce
    // itself on the network for a user who had turned the receiver off.
    running: root.receiverConfigured && root.receiverEnabled && root.pluginVersion !== ""
    stdinEnabled: true
    stdout: SplitParser {
      readonly property var owner: root
      onRead: function(line) {
        if (!owner || owner.tearingDown || typeof owner.handleEvent !== "function") return
        owner.handleEvent(Model.parseLine(line))
      }
    }
    stderr: SplitParser { onRead: function(line) { console.warn("nearby backend", line) } }
    onStarted: {
      backend.launched=true
      if (!owner || owner.tearingDown || typeof owner.noteBackendStarted !== "function") return
      owner.noteBackendStarted()
    }
    // A helper that is missing rather than failing never reaches onExited:
    // Quickshell returns running to false without an exit code, the same way
    // the file chooser and clipboard readers report a command that never ran.
    // This is the case reinstalling actually fixes.
    onRunningChanged: {
      if (running) { backend.launched=false; return }
      if (backend.launched) return
      if (!owner || owner.tearingDown || typeof owner.noteBackendNeverLaunched !== "function") return
      owner.noteBackendNeverLaunched()
    }
    onExited: function(code) {
      if (!owner || owner.tearingDown || typeof owner.handleBackendExit !== "function") return
      owner.handleBackendExit(code)
    }
  }
  function noteBackendStarted() {
    backendAcceptedThisRun=false
    backendVersionMismatch=false
    helperMissing=false
    backendStartupFailureCode=""
    backendStartupFailurePort=0
  }
  function noteBackendNeverLaunched() {
    // `running` is a binding, so it also drops when the receiver is turned
    // off or the manifest version goes away. Only a helper we still want
    // running counts as one that failed to launch.
    if (!receiverEnabled || pluginVersion === "") return
    backendReady=false
    helperMissing=true
    reportFailure("Helper unavailable",
      "Nearby could not prepare its verified helper. Connect to the internet and try Retry helper, or build it with ./build.sh.")
  }
  Process {
    id: helperUpdater
    readonly property var owner: root
    property bool launched: false
    command: [root.pluginDir + "/bin/nearby-repair-helper"]
    running: false
    stdout: SplitParser {
      readonly property var owner: root
      onRead: function(line) {
        if (!owner || owner.tearingDown || typeof owner.handleUpdaterEvent !== "function") return
        owner.handleUpdaterEvent(Model.parseLine(line))
      }
    }
    stderr: SplitParser { onRead: function(line) { console.warn("nearby helper repair", line) } }
    onStarted: helperUpdater.launched=true
    // Same missing-command signal the helper and the file chooser use: no exit
    // code ever arrives, so an absent repair command has to be caught here.
    onRunningChanged: {
      if (running || helperUpdater.launched) return
      if (!owner || owner.tearingDown || typeof owner.noteUpdaterNeverLaunched !== "function") return
      owner.noteUpdaterNeverLaunched()
    }
    onExited: function(code) {
      if (!owner || owner.tearingDown || typeof owner.finishHelperUpdate !== "function") return
      owner.finishHelperUpdate(code)
    }
  }
  function noteUpdaterNeverLaunched() {
    helperUpdating=false
    helperUpdateStatus=""
    helperUpdateError="The Nearby helper repair command is missing. Run omarchy plugin update oma.nearby."
  }
  Timer { id: backendRestart; property int attempts: 0; interval: 1000; repeat: false; onTriggered: if (root.receiverEnabled && !backend.running) root.bindBackendRunning() }
  Timer { id: nameRestart; interval: 1200; repeat: false; onTriggered: root.restartForName() }
  Timer { id: nameShutdownFallback; interval: 2000; repeat: false; onTriggered: root.finishNameShutdown() }
  Timer { id: receiverShutdownFallback; interval: 250; repeat: false; onTriggered: root.finishReceiverShutdown() }

  QuickShare {
    id: quickShareEngine
    pluginDir: root.pluginDir
    advertisedName: root.advertisedName
    onCursorRequested: function(index) { root.cursorRequested(index) }
  }
}
