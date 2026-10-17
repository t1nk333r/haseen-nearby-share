import QtQuick
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons
import "Model.js" as Model

Panel {
  id: root
  moduleName: "t1nk33r.nearby-share"
  // The `t1nk33r.nearby-share` IPC target belongs to the service, which exists
  // once. A widget registering it would register it once per monitor.
  manageIpc: false

  // The host may replace moduleName with an instance id. Keep the manifest id
  // stable for registry lookups and filesystem paths.
  readonly property string manifestPluginId: "t1nk33r.nearby-share"

  // The bar builds one of these per monitor, so this file owns no helper, no
  // transfer state, and no IPC target. All of that lives in the `service`
  // entry point, which the shell loads exactly once; everything below is a
  // view onto it plus this popup's own cursor. See Service.qml.
  // The engine, through whichever door this host can open. Omarchy's own bar
  // hands a registered widget a service-capable façade; a replacement bar gets
  // `pluginShellForBarEntry`, which has no service lookup at all, so the shell
  // is asked first and Bridge.qml answers when it cannot. The service publishes
  // itself there, so the view is never left without its engine - which is what
  // a widget with no engine looks like from the outside: icon painting the
  // "turned off" colour over a receiver that is running, and a popup that can
  // start nothing. See Bridge.qml.
  readonly property var engine: {
    var viaShell = bar && bar.shell && typeof bar.shell.serviceFor === "function"
      ? bar.shell.serviceFor(manifestPluginId)
      : null
    return viaShell || Bridge.service
  }

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.4)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color barIconColor: root.receiverEnabled ? barForeground : Qt.darker(barForeground, 1.55)

  // Engine state, read under the names the popup already used. A view with no
  // engine says so rather than rendering an empty panel.
  // Which pane is drawn. The engine owns the answer, and it is not simply the
  // stored preference: when the CLI is missing or the radio is down the engine
  // falls the pane back to LocalSend, because the switcher is hidden in that
  // state and the Quick Share pane has nothing to show and no way out of itself.
  // Asking the engine rather than recomputing it here keeps one verdict in one
  // place; with no engine at all, LocalSend is the pane that always works.
  readonly property bool quickShareMode: engine ? engine.quickShareMode : false
  readonly property var qs: engine ? engine.quickshare : null

  // The Quick Share pane's own state, read under names that parallel the
  // LocalSend ones above rather than reaching into `qs` at every use.
  readonly property bool qsAvailable: qs ? qs.available : false
  readonly property bool qsChecked: qs ? qs.depsChecked : false
  readonly property bool qsScanning: qs ? qs.scanning : false
  readonly property var qsDevices: qs ? qs.devices : []
  readonly property var qsSelected: qs ? qs.selectedDevice : null
  readonly property string qsViewState: qs ? qs.viewState : "nearby"
  readonly property string qsStatusText: qs ? qs.statusText : "Quick Share engine is not loaded."
  readonly property string qsErrorText: qs ? qs.errorText : ""
  readonly property real qsProgress: qs ? qs.progress : 0
  readonly property string qsTransferName: qs ? qs.transferName : ""
  readonly property string qsTransferPeer: qs ? qs.transferPeer : ""
  readonly property string qsTransferPin: qs ? qs.transferPin : ""
  readonly property var qsMissingDeps: qs ? qs.missingDeps : []
  // The radio's own sentence, when it has one: a machine can have every
  // dependency and still not run this, and the pane names which case it is.
  readonly property string qsRadioReason: qs && qs.radioReason ? qs.radioReason : ""

  // The engine resolves the plugin directory from its own manifest metadata,
  // which is the only place that knows where an installed copy actually is.
  readonly property string qsScriptDir: (engine && engine.pluginDir
    ? engine.pluginDir
    : (Quickshell.env("HOME") || "") + "/.config/omarchy/plugins/" + manifestPluginId) + "/scripts"
  // That directory is interpolated into a `bash -c` string between single
  // quotes, so a quote anywhere in it would end the quoted region early and the
  // rest of the path would be read as commands. '\'' is the only escape a
  // single-quoted string has: close it, escape the quote, reopen it.
  readonly property string qsScriptDirQuoted: qsScriptDir.replace(/'/g, "'\\''")

  // Last reachable cursor row in the Quick Share pane. Index -2 is the mode
  // switcher in both panes; dx there flips protocol rather than moving,
  // because the two buttons are one control.
  readonly property int qsLastIndex: qsViewState !== "nearby"
    ? 0
    : (qsAvailable ? qsDevices.length : 0)

  readonly property string deviceNameMode: engine ? engine.deviceNameMode : "hostname"
  readonly property string customDeviceName: engine ? engine.customDeviceName : ""
  readonly property string advertisedName: engine ? engine.advertisedName : ""
  readonly property string systemHostname: engine ? engine.systemHostname : ""
  readonly property string generatedPreview: engine ? engine.generatedName : ""

  readonly property bool backendReady: engine ? engine.backendReady : false
  readonly property bool receiverEnabled: engine ? engine.receiverEnabled : false
  readonly property bool discoveryActive: engine ? engine.discoveryActive : false
  readonly property var devices: engine ? engine.devices : []
  readonly property var selectedDevice: engine ? engine.selectedDevice : null
  readonly property string viewState: engine ? engine.viewState : "nearby"
  readonly property string statusText: engine ? engine.statusText : "Nearby engine is not loaded."
  readonly property string errorText: engine ? engine.errorText : "Nearby engine is not loaded."
  readonly property var incomingQueue: engine ? engine.incomingQueue : []
  readonly property var incoming: engine ? engine.incoming : null
  readonly property string incomingText: engine ? engine.incomingText : ""
  readonly property real progress: engine ? engine.progress : 0
  readonly property string transferName: engine ? engine.transferName : ""
  readonly property string transferPeer: engine ? engine.transferPeer : ""
  readonly property string pinError: engine ? engine.pinError : ""
  readonly property bool incomingPinEnabled: engine ? engine.incomingPinEnabled : false
  readonly property bool incomingPinUpdating: engine ? engine.incomingPinUpdating : false
  readonly property string incomingPinError: engine ? engine.incomingPinError : ""
  readonly property bool helperUpdateOffered: engine ? engine.helperUpdateOffered : false
  readonly property bool helperUpdating: engine ? engine.helperUpdating : false
  readonly property string helperUpdateStatus: engine ? engine.helperUpdateStatus : ""
  readonly property string helperUpdateError: engine ? engine.helperUpdateError : ""
  readonly property string helperUpdateDetail: engine ? engine.helperUpdateDetail : ""
  // An unusable helper takes the whole view over: there are no devices to list
  // and none are coming, so the section stops calling itself DEVICES.
  readonly property bool helperBlocksNearby: helperUpdateOffered && !backendReady

  // Shown only when helper recovery fails, so the user can refresh the tracked
  // plugin source through Omarchy or inspect its repository.
  readonly property string repositoryUrl: "https://github.com/t1nk333r/omarchy-nearby-share" // fork URL kept over upstream's
  readonly property string updateCommand: "omarchy plugin update t1nk33r.nearby-share" // fork plugin id kept over upstream's

  // The update row sits after the devices and compact action row. If updating
  // fails, its two recovery actions follow it in keyboard order.
  readonly property int helperUpdateIndex: !helperUpdateOffered
    ? -1
    : (receiverEnabled && backendReady ? devices.length + 2 : devices.length)
  readonly property int helperCopyCommandIndex: helperUpdateError === "" || helperUpdateIndex < 0
    ? -1 : helperUpdateIndex + 1
  readonly property int helperCopyLinkIndex: helperCopyCommandIndex < 0
    ? -1 : helperCopyCommandIndex + 1

  // Cursor and popup focus are per monitor, so they stay here.
  property int selectedIndex: 0
  property bool cursorActive: false
  property int nearbyPhraseIndex: 0
  property bool viewRegistered: false
  property string copyNote: ""

  readonly property var nearbyPhrases: [
    "Looking nearby",
    "Finding devices",
    "Listening locally",
    "Ready to receive",
    "Watching the LAN",
    "Checking the air"
  ]
  readonly property bool rotatingPhrases: opened && receiverEnabled && backendReady && viewState === "nearby" && errorText === ""
  readonly property string heroMetaText: {
    if (viewState === "nearby") {
      if (!receiverEnabled) return "Turned off"
      // statusText, never errorText: this line is uppercased and letterspaced,
      // so a full sentence crops mid-word and the body below is already saying
      // the same thing in full.
      if (!backendReady) return statusText
      return nearbyPhrases[nearbyPhraseIndex % nearbyPhrases.length]
    }
    if (viewState === "incoming_pin_settings") return incomingPinEnabled ? "Protection enabled" : "Protection disabled"
    if (viewState === "incoming_pin_edit") return incomingPinEnabled ? "Change protection" : "Enable protection"
    if (viewState === "incoming_pin_disable") return "Confirm disable"
    if (viewState === "target") return "Ready to receive"
    return statusText
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Component.onCompleted: syncOpenState()

  // Discovery follows the popup and there is one popup per monitor, so the
  // engine counts open views instead of tracking a single flag.
  function syncOpenState() {
    if (!engine || opened === viewRegistered) return
    viewRegistered = opened
    if (opened) engine.viewOpened()
    else engine.viewClosed()
  }
  onEngineChanged: { viewRegistered = false; syncOpenState() }
  Component.onDestruction: if (engine && viewRegistered) engine.viewClosed()

  Connections {
    target: root.engine
    function onCursorRequested(index) { root.selectedIndex = index }
    function onPinCleared() { pinInput.text = "" }
    function onPinFocusRequested() { if (root.opened) Qt.callLater(function(){ pinInput.forceActiveFocus() }) }
    function onIncomingPinCleared() { incomingPinInput.text = "" }
    function onIncomingPinFocusRequested() { if (root.opened) Qt.callLater(function(){ incomingPinInput.forceActiveFocus() }) }
    function onCustomNameFocusRequested() { if (root.opened) Qt.callLater(function(){ nameInput.forceActiveFocus() }) }
    function onFocusRestoreRequested() { if (root.opened) Qt.callLater(function(){ keyCatcher.forceActiveFocus() }) }
  }

  function setMode(next) { if (engine) engine.setMode(next) }
  function qsScan() { if (qs) qs.scan() }
  function qsChooseDevice(index) { if (qs) qs.chooseDevice(index) }
  function qsBack() { if (qs) qs.clearTarget() }
  function qsCancel() { if (qs) qs.cancelSend() }
  function qsFinish() { if (qs) qs.finishTerminal() }
  // The chooser belongs to the monitor the user acted on, same as LocalSend's.
  function qsSelectFiles() { if (!qsSelected || qsPicker.running) return; qsPicker.launched = false; qsPicker.running = true }
  function installDependencies() { if (!depsInstaller.running) depsInstaller.running = true }
  function configureFirewall() { if (!firewallSetup.running) firewallSetup.running = true }

  function openDeviceName() { if (engine) engine.openDeviceName() }
  function closeDeviceName() { if (engine) engine.closeDeviceName() }
  function chooseNameMode(mode) { if (engine) engine.chooseNameMode(mode) }
  function submitCustomName() { if (engine) engine.submitCustomName(String(nameInput.text || "")) }
  function focusCustomName() { if (engine) engine.requestCustomNameFocus() }

  function toggleReceiver() { if (engine) engine.toggleReceiver() }
  function startDiscovery() { if (engine) engine.startDiscovery() }
  function forceFullDiscovery() { if (engine) engine.forceFullDiscovery() }
  function chooseDevice(index) { if (engine) engine.chooseDevice(index) }
  function acceptIncoming() { if (engine) engine.acceptIncoming() }
  function declineIncoming() { if (engine) engine.declineIncoming() }
  function finishText() { if (engine) engine.finishText() }
  function finishTerminal() { if (engine) engine.finishTerminal() }
  function cancelOutgoing() { if (engine) engine.cancelOutgoing() }
  function cancelPin() { if (engine) engine.cancelPin() }
  function retryWithPin() { if (engine) engine.retryWithPin(String(pinInput.text || "")) }
  function openIncomingPinSettings() { if (engine) engine.openIncomingPinSettings() }
  function beginIncomingPinEdit() { if (engine) engine.beginIncomingPinEdit() }
  function requestDisableIncomingPin() { if (engine) engine.requestDisableIncomingPin() }
  function cancelIncomingPinSettings() { if (engine) engine.cancelIncomingPinSettings() }
  function submitIncomingPin() { if (engine) engine.submitIncomingPin(String(incomingPinInput.text || "")) }
  function confirmDisableIncomingPin() { if (engine) engine.confirmDisableIncomingPin() }
  function clearSecretInputs() { pinInput.text = ""; incomingPinInput.text = "" }
  function retryHelper() { copyNote=""; if (engine) engine.startHelperUpdate() }
  function copyText(value) { if (textCopier.running) return; copyNote=""; textCopier.payload=String(value); textCopier.launched=false; textCopier.running=true }
  function copyUpdateCommand() { copyText(updateCommand) }
  function copyRepositoryLink() { copyText(repositoryUrl) }
  function failWith(message) { if (engine) engine.failWith(message) }
  function noteTextCopied() { if (engine) engine.noteTextCopied() }
  function beginOutgoing(pending) { if (engine) engine.beginOutgoing(pending) }
  function goBack() {
    if (quickShareMode) {
      if (qsViewState === "target") { qsBack(); return }
      if (qsViewState === "success" || qsViewState === "error") { qsFinish(); return }
      close(); return
    }
    return goBackLocalSend()
  }
  function goBackLocalSend() { if (viewState === "device_name") { closeDeviceName(); return } if (viewState === "pin") cancelPin(); else if (viewState.indexOf("incoming_pin_")===0) cancelIncomingPinSettings(); else if (viewState === "target") { if (engine) engine.clearTarget() } else close() }

  // The chooser and the clipboard belong to the monitor the user acted on, so
  // they stay with the view and hand their result to the engine.
  function selectFiles() { if (!selectedDevice || picker.running) return; picker.launched=false; picker.running = true }
  function sendClipboard() { if (!selectedDevice || clipboard.running) return; clipboard.launched=false; clipboard.running = true }
  function copyReceivedText() { clipboardWriter.launched=false; clipboardWriter.running=true }

  // The kit's Button already paints its own mouse hover from containsMouse.
  // `hasCursor` is this panel's keyboard cursor, and the handlers only ever
  // took it: pointing the cursor at whatever the mouse touched and never
  // letting go, so the last button the pointer crossed stayed lit after it had
  // moved away, and two things looked hovered at once.
  //
  // Taking it on enter and releasing it on leave keeps one highlight, under the
  // pointer. selectedIndex survives the release so an arrow key resumes from
  // where the mouse left off rather than from the top.
  //
  // The release is guarded by index because entering the next button can be
  // delivered before leaving the previous one; unguarded, that order would
  // clear the highlight on the button the pointer is now sitting on.
  function noteHover(on, index) {
    if (on) { cursorActive = true; selectedIndex = index }
    else if (selectedIndex === index) cursorActive = false
  }

  function moveCursor(dx, dy) {
    cursorActive = true
    if (viewState === "device_name" && !quickShareMode) {
      if (dy !== 0) selectedIndex = Math.max(0, Math.min(4, selectedIndex + dy))
      return
    }
    // The switcher's row (-2) is only a stop while the switcher is drawn: with
    // the engine unavailable -- no CLI, or the radio down -- the pane has
    // nothing to switch to, so -2 becomes a gap the walk steps over and the
    // Quick Share pane's own rows start at 0.
    if (qsAvailable && selectedIndex === -2 && dx !== 0) {
      setMode(dx > 0 ? "quickshare" : "localsend")
      return
    }
    if (quickShareMode) {
      var qsFloor = qsAvailable ? -2 : 0
      if (qsViewState === "target") {
        // 0 Send files, 1 Back. The ceiling was 2, one past the last row the
        // pane draws, so the walk stopped on a row that is not there and Enter
        // on it performed Back a second time.
        if (dy !== 0) selectedIndex = Math.max(qsFloor, Math.min(1, selectedIndex + dy))
        return
      }
      if (qsViewState === "sending" || qsViewState === "success" || qsViewState === "error") {
        if (dy !== 0) selectedIndex = Math.max(qsFloor, Math.min(0, selectedIndex + dy))
        return
      }
      if (dy !== 0) selectedIndex = Math.max(qsFloor, Math.min(qsLastIndex, selectedIndex + dy))
      return
    }
    if (viewState === "nearby") {
      // The update row is the last stop until a failure reveals the two
      // recovery actions that follow it.
      var lastNearbyIndex=helperCopyLinkIndex>=0
        ? helperCopyLinkIndex
        : (helperUpdateIndex>=0
          ? helperUpdateIndex
          : (receiverEnabled&&backendReady ? devices.length+1 : Math.max(-1,devices.length-1)))
      if (dx !== 0 && helperCopyCommandIndex >= 0 && selectedIndex >= helperCopyCommandIndex) {
        selectedIndex = Math.max(helperCopyCommandIndex, Math.min(helperCopyLinkIndex, selectedIndex + dx))
        return
      }
      if (dx !== 0 && selectedIndex >= devices.length) {
        selectedIndex = Math.max(devices.length, Math.min(lastNearbyIndex, selectedIndex + dx))
        return
      }
      if (dy !== 0) {
        // -2 is the switcher's row. While the engine is unavailable the
        // switcher is not drawn, so the walk carries past the gap instead of
        // stopping on a row with nothing in it.
        var nextRow = selectedIndex + dy
        if (!qsAvailable && nextRow === -2) nextRow += dy > 0 ? 1 : -1
        selectedIndex = Math.max(-3, Math.min(lastNearbyIndex, nextRow))
      }
      return
    }
    if (dx !== 0 && (viewState === "incoming" || viewState === "text" || viewState === "incoming_pin_disable")) {
      selectedIndex = Math.max(0, Math.min(1, selectedIndex + dx))
      return
    }
    if (dx !== 0 && viewState === "incoming_pin_settings" && incomingPinEnabled && selectedIndex < 2) {
      selectedIndex = Math.max(0, Math.min(1, selectedIndex + dx))
      return
    }
    var count = viewState === "target" ? 3 : ((viewState === "incoming" || viewState === "text" || viewState === "incoming_pin_disable") ? 2 : (viewState === "incoming_pin_settings" ? (incomingPinEnabled ? 3 : 2) : 1))
    if (count > 0 && dy !== 0) selectedIndex = Math.max(0, Math.min(count - 1, selectedIndex + dy))
  }
  function activateCursor() {
    if (viewState === "device_name" && !quickShareMode) {
      if (selectedIndex === 0) chooseNameMode("hostname")
      else if (selectedIndex === 1) chooseNameMode("generated")
      else if (selectedIndex === 2) chooseNameMode("custom")
      else if (selectedIndex === 3) focusCustomName()
      else closeDeviceName()
      return
    }
    if (qsAvailable && selectedIndex === -2) { setMode(quickShareMode ? "localsend" : "quickshare"); return }
    if (quickShareMode) {
      if (qsViewState === "target") {
        if (selectedIndex === 0) qsSelectFiles()
        else qsBack()
        return
      }
      if (qsViewState === "sending") { qsCancel(); return }
      if (qsViewState === "success" || qsViewState === "error") { qsFinish(); return }
      // Only a missing helper is worth an install; a radio that is down is not
      // something the installer can fix, and the pane's text says so.
      if (!qsAvailable) { if (qsMissingDeps.length > 0) installDependencies(); return }
      if (selectedIndex >= 0 && selectedIndex < qsDevices.length) qsChooseDevice(selectedIndex)
      else if (selectedIndex === qsDevices.length) qsScan()
      return
    }
    // Below the Quick Share branch deliberately: the cog belongs to the
    // LocalSend hero, and firing it from the other pane opened a view that
    // pane cannot render and cannot leave.
    if (selectedIndex === -3) { openDeviceName(); return }
    if (viewState === "nearby") {
      // Checked before the action row: with the helper unusable that row is
      // hidden, and the update button takes the index rescan would have had.
      if (selectedIndex === -1) toggleReceiver()
      else if (helperUpdateIndex >= 0 && selectedIndex === helperUpdateIndex) retryHelper()
      else if (helperCopyCommandIndex >= 0 && selectedIndex === helperCopyCommandIndex) copyUpdateCommand()
      else if (helperCopyLinkIndex >= 0 && selectedIndex === helperCopyLinkIndex) copyRepositoryLink()
      else if (selectedIndex < devices.length) chooseDevice(selectedIndex)
      else if (receiverEnabled && backendReady && selectedIndex === devices.length) forceFullDiscovery()
      else if (receiverEnabled && backendReady && selectedIndex === devices.length+1) openIncomingPinSettings()
    }
    else if (viewState === "target") selectedIndex === 0 ? selectFiles() : (selectedIndex === 1 ? sendClipboard() : goBack())
    else if (viewState === "incoming") selectedIndex === 0 ? declineIncoming() : acceptIncoming()
    else if (viewState === "text") { if(selectedIndex===0)copyReceivedText(); else finishText() }
    else if (viewState === "incoming_pin_settings") incomingPinEnabled ? (selectedIndex===0?beginIncomingPinEdit():(selectedIndex===1?requestDisableIncomingPin():goBack())) : (selectedIndex===0?beginIncomingPinEdit():goBack())
    else if (viewState === "incoming_pin_disable") selectedIndex===0 ? cancelIncomingPinSettings() : confirmDisableIncomingPin()
    else if (viewState === "sending") cancelOutgoing()
    else if (viewState === "success" || viewState === "error") finishTerminal()
  }

  onOpenedChanged: {
    if (opened) {
      cursorActive=false; selectedIndex=-1; nearbyPhraseIndex=0
      syncOpenState()
      Qt.callLater(function(){ if (root.viewState==="pin") pinInput.forceActiveFocus(); else if(root.viewState==="incoming_pin_edit")incomingPinInput.forceActiveFocus(); else keyCatcher.forceActiveFocus() })
    } else { clearSecretInputs(); syncOpenState() }
  }

  Timer {
    id: nearbyPhraseTimer
    interval: 2800
    running: root.rotatingPhrases
    repeat: true
    onTriggered: nearbyPhraseSwap.restart()
  }

  SequentialAnimation {
    id: nearbyPhraseSwap
    PropertyAnimation {
      target: hero; property: "metaOpacity"
      to: 0.0; duration: 180; easing.type: Easing.OutQuad
    }
    ScriptAction {
      script: root.nearbyPhraseIndex = (root.nearbyPhraseIndex + 1) % root.nearbyPhrases.length
    }
    PropertyAnimation {
      target: hero; property: "metaOpacity"
      to: 1.0; duration: 260; easing.type: Easing.InQuad
    }
  }

  onRotatingPhrasesChanged: {
    if (!rotatingPhrases) {
      nearbyPhraseSwap.stop()
      hero.metaOpacity = 1.0
    }
  }

  // Quickshell reports a command it could not launch by returning `running` to
  // false without ever emitting `started` or `exited`, so a missing binary has
  // to be caught there. Exit codes never carry that news: nothing runs a shell
  // on our behalf, so the 127 a shell would report cannot reach us.
  Process {
    id: picker
    property bool launched: false
    command: ["omarchy-file-select","--title","Send nearby","--multiple"]
    running: false
    stdout: StdioCollector { id: pickerOutput; waitForEnd: true }
    onStarted: picker.launched=true
    onRunningChanged: if (!running && !picker.launched) root.failWith("The file chooser could not be started")
    onExited: function(code) {
      // The chooser separates a decision from a fault: 1 is nobody picking
      // anything, and anything above it is a chooser that never opened.
      if (code > 1) { root.failWith("The file chooser did not open"); return }
      if (code !== 0 || !root.selectedDevice) return
      var paths=String(pickerOutput.text || "").split("\n").filter(function(v){return v.trim()!==""})
      if (paths.length) root.beginOutgoing({kind:"files",device:root.selectedDevice,paths:paths})
    }
  }
  Process {
    id: clipboard
    property bool launched: false
    command: ["wl-paste","--no-newline","--type","text"]
    running: false
    stdout: StdioCollector { id: clipboardOutput; waitForEnd: true }
    onStarted: clipboard.launched=true
    onRunningChanged: if (!running && !clipboard.launched) root.failWith("wl-paste is required to read the clipboard")
    onExited: function(code) {
      var text=String(clipboardOutput.text || "")
      if (code===0 && text.trim()!=="" && root.selectedDevice) root.beginOutgoing({kind:"text",device:root.selectedDevice,text:text})
      else root.failWith("Clipboard is empty")
    }
  }

  BarIconButton {
    id: button; anchors.fill: parent; bar: root.bar; text: "\u{f02b9}"
    foreground: root.barIconColor
    active: root.incoming !== null || root.viewState === "receiving" || root.viewState === "sending" || root.viewState === "pin"
    tooltipText: !root.receiverEnabled ? "Nearby · Turned off" : (root.backendReady ? (root.viewState === "pin" ? "Nearby · PIN required" : (root.incoming ? "Incoming transfer" : "Nearby · Ready to receive")) : "Nearby · Receiver unavailable")
    onPressed: function(code) { root.toggle() }
  }

  KeyboardPanel {
    id: panel; anchorItem: button; owner: root; bar: root.bar; open: root.opened; focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(360))
    contentHeight: panel.fittedContentHeight(content.implicitHeight, Style.space(560))
    PanelKeyCatcher {
      id: keyCatcher; anchors.fill: parent
      blocked: (root.viewState==="pin" && pinInput.activeFocus)||(root.viewState==="incoming_pin_edit"&&incomingPinInput.activeFocus)||(root.viewState==="device_name"&&nameInput.activeFocus)
      onMoveRequested: function(dx,dy){root.moveCursor(dx,dy)}
      onActivateRequested: root.activateCursor()
      onCloseRequested: root.goBack()
      Column {
        id: content; width: parent.width; spacing: Style.space(12)
        PanelHero {
          id: hero
          title: root.viewState.indexOf("incoming_pin_")===0 ? "Incoming PIN" : ((root.viewState === "target" || root.viewState === "pin") && root.selectedDevice ? root.selectedDevice.alias : (root.viewState === "incoming" ? "Incoming" : "Nearby"))
          meta: root.heroMetaText
          detail: ""
          foreground: root.foreground; fontFamily: root.fontFamily
          iconComponent: Component { Text { text: root.viewState === "incoming" ? "\u{f0045}" : "\u{f02b9}"; color: root.incoming ? root.urgent : root.foreground; font.family:root.fontFamily; font.pixelSize:Style.font.display } }
          trailingControl: !root.quickShareMode && root.viewState === "nearby" ? nearbyHeroControls : null
        }
        Component {
          id: nearbyHeroControls
          Row {
            spacing: Style.space(8)
            Button {
              bordered: false; iconText: "\u{f0493}"; text: ""
              tooltipText: "Device name"
              foreground: root.dim; fontFamily: root.fontFamily
              hasCursor: root.cursorActive && root.selectedIndex === -3
              onHovered: function(v) { root.noteHover(v, -3) }
              onClicked: root.openDeviceName()
            }
          ToggleSwitch {
            checked: root.receiverEnabled
            hasCursor: root.cursorActive && root.selectedIndex === -1
            foreground: root.foreground
            onHovered: function(on) { root.noteHover(on, -1) }
            onToggled: root.toggleReceiver()
            PanelToolTip { visible: parent.containsMouse; text: root.receiverEnabled ? "Turn Nearby off" : "Turn Nearby on"; fontFamily:root.fontFamily }
          }
          }
        }
        PanelSeparator { visible: root.qsAvailable; width: parent.width }

        // The two protocols, given equal weight. They are genuinely separate
        // stacks -- a different transport, a different device list, a
        // different binary -- so this switches panes rather than filtering one
        // combined list that could never merge cleanly.
        Row {
          id: modeSwitch
          // Hidden, not removed, when the engine cannot run: a control that
          // switches to a pane which cannot work is worse than no control, and
          // this way it returns on its own when the radio does.
          visible: root.qsAvailable
          width: parent.width; spacing: Style.space(8)
          Button {
            width: (parent.width - parent.spacing) / 2
            bordered: !root.quickShareMode
            iconText: "󰀂"
            text: "LocalSend"
            tooltipText: "LocalSend-compatible sharing"
            foreground: root.quickShareMode ? root.dim : root.foreground
            fontFamily: root.fontFamily
            hasCursor: root.cursorActive && root.selectedIndex === -2 && !root.quickShareMode
            onHovered: function(v) { root.noteHover(v, -2) }
            onClicked: root.setMode("localsend")
          }
          Button {
            width: (parent.width - parent.spacing) / 2
            bordered: root.quickShareMode
            iconText: "󰄜"
            text: "Quick Share"
            tooltipText: "Google Quick Share (Nearby Share)"
            foreground: root.quickShareMode ? root.foreground : root.dim
            fontFamily: root.fontFamily
            hasCursor: root.cursorActive && root.selectedIndex === -2 && root.quickShareMode
            onHovered: function(v) { root.noteHover(v, -2) }
            onClicked: root.setMode("quickshare")
          }
        }
        PanelSeparator { visible: root.qsAvailable; width: parent.width }

        Column {
          visible: !root.quickShareMode && root.viewState === "nearby"; width: parent.width; spacing: Style.space(6)
          PanelSectionHeader { text: root.helperBlocksNearby ? "HELPER" : "DEVICES"; foreground:root.foreground; fontFamily:root.fontFamily }
          // Silent while the helper row owns the view: its text there was
          // errorText, which the row states once already.
          Text { visible: root.devices.length===0 && !root.helperBlocksNearby; width:parent.width; textFormat:Text.PlainText; text: !root.receiverEnabled ? "Nearby is turned off" : (root.discoveryActive ? "Finding devices…" : (root.backendReady ? "No devices nearby" : root.errorText)); wrapMode:Text.Wrap; color:root.dim; font.family:root.fontFamily; font.pixelSize:Style.font.body; topPadding:Style.space(12); bottomPadding:Style.space(12) }
          Repeater {
            model: root.devices
            Button { required property var modelData; required property int index; width:parent.width; leftAlign:true; bordered:false; iconText:Model.iconFor(modelData.deviceType); text:modelData.alias; foreground:root.foreground; fontFamily:root.fontFamily; hasCursor:root.cursorActive&&root.selectedIndex===index; onHovered:function(v){root.noteHover(v,index)}; onClicked:root.chooseDevice(index) }
          }
          Row {
            id:nearbyActions; visible:root.receiverEnabled&&root.backendReady; width:parent.width; spacing:Style.space(8)
            Button { width:(parent.width-parent.spacing)/2; bordered:false; iconText:"󰑐"; text:"Rescan"; tooltipText:"Search for new devices"; foreground:root.foreground; fontFamily:root.fontFamily; hasCursor:root.cursorActive&&root.selectedIndex===root.devices.length; onHovered:function(v){root.noteHover(v,root.devices.length)}; onClicked:root.forceFullDiscovery() }
            Button { width:(parent.width-parent.spacing)/2; bordered:false; iconText:"󰌾"; text:"PIN · "+(root.incomingPinEnabled?"On":"Off"); tooltipText:"Incoming PIN settings"; foreground:root.foreground; fontFamily:root.fontFamily; hasCursor:root.cursorActive&&root.selectedIndex===root.devices.length+1; onHovered:function(v){root.noteHover(v,root.devices.length+1)}; onClicked:root.openIncomingPinSettings() }
          }

          // The checkout pins immutable helper bytes. The launcher resolves
          // them outside the plugin tree, and this action retries/prefetches
          // that exact helper when automatic startup cannot do so.
          Column {
            id: helperUpdate
            visible: root.helperUpdateOffered; width:parent.width; spacing:Style.space(6)
            // Only when it follows something. With the helper blocking the
            // view this row is the section, and a rule under its own header
            // separates nothing.
            PanelSeparator { visible:!root.helperBlocksNearby; width:parent.width }

            // The versions, once. Replaced by live progress while the repair
            // runs so the button is not the only thing that moves.
            Text {
              width:parent.width; textFormat:Text.PlainText; wrapMode:Text.Wrap
              text: root.helperUpdating && root.helperUpdateStatus!=="" ? root.helperUpdateStatus : root.helperUpdateDetail
              color: root.helperUpdating ? root.dim : root.foreground
              font.family:root.fontFamily; font.pixelSize:Style.font.body
            }
            Text {
              visible:!root.helperUpdating; width:parent.width; textFormat:Text.PlainText; wrapMode:Text.Wrap
              text:"Nearby will fetch and verify the helper selected by this plugin."
              color:root.dim; font.family:root.fontFamily; font.pixelSize:Style.font.body
            }
            Button {
              width:parent.width; bordered:true
              iconText: root.helperUpdateError!=="" && !root.helperUpdating ? "󰑐" : "󰇚"
              // After a failure the old label gives no sign the press landed,
              // and the error above it stays put; naming the retry is the only
              // thing that distinguishes "not pressed yet" from "pressed once".
              text: root.helperUpdating ? "Preparing…" : (root.helperUpdateError!=="" ? "Try again" : "Retry helper")
              tooltipText:"Prepare the verified helper selected by this plugin"
              enabled:!root.helperUpdating
              foreground:root.foreground; fontFamily:root.fontFamily
              hasCursor:root.cursorActive&&root.selectedIndex===root.helperUpdateIndex
              onHovered:function(v){root.noteHover(v,root.helperUpdateIndex)}
              onClicked:root.retryHelper()
            }

            // The fallback is subordinate to the failure, so it sits under a
            // rule of its own rather than continuing the same flat stack.
            Column {
              visible:root.helperUpdateError!==""; width:parent.width; spacing:Style.space(6)
              Text { width:parent.width; textFormat:Text.PlainText; text:root.helperUpdateError; wrapMode:Text.Wrap; color:root.urgent; font.family:root.fontFamily; font.pixelSize:Style.font.body }
              PanelSeparator { width:parent.width }
              Text { width:parent.width; textFormat:Text.PlainText; text:"Or run this in a terminal:"; color:root.dim; font.family:root.fontFamily; font.pixelSize:Style.font.body }
              Text { width:parent.width; textFormat:Text.PlainText; text:root.updateCommand; elide:Text.ElideMiddle; color:root.foreground; font.family:root.fontFamily; font.pixelSize:Style.font.body }
              Row {
                width:parent.width; spacing:Style.space(8)
                Button { width:(parent.width-parent.spacing)/2; bordered:true; iconText:"󰆏"; text:"Copy command"; tooltipText:root.updateCommand; foreground:root.foreground; fontFamily:root.fontFamily; hasCursor:root.cursorActive&&root.selectedIndex===root.helperCopyCommandIndex; onHovered:function(v){root.noteHover(v,root.helperCopyCommandIndex)}; onClicked:root.copyUpdateCommand() }
                Button { width:(parent.width-parent.spacing)/2; bordered:false; iconText:"󰌷"; text:"Copy link"; tooltipText:root.repositoryUrl; foreground:root.dim; fontFamily:root.fontFamily; hasCursor:root.cursorActive&&root.selectedIndex===root.helperCopyLinkIndex; onHovered:function(v){root.noteHover(v,root.helperCopyLinkIndex)}; onClicked:root.copyRepositoryLink() }
              }
              Text { visible:root.copyNote!==""; width:parent.width; textFormat:Text.PlainText; text:root.copyNote; color:root.dim; font.family:root.fontFamily; font.pixelSize:Style.font.body }
            }
          }
        }

        Column {
          visible: !root.quickShareMode && root.viewState === "target"; width:parent.width; spacing:Style.space(6)
          PanelSectionHeader { text:"SEND"; foreground:root.foreground; fontFamily:root.fontFamily }
          Button { width:parent.width; leftAlign:true; iconText:"󰈔"; text:"Send files"; foreground:root.foreground; fontFamily:root.fontFamily; hasCursor:root.cursorActive&&root.selectedIndex===0; onHovered:function(v){root.noteHover(v,0)}; onClicked:root.selectFiles() }
          Button { width:parent.width; leftAlign:true; iconText:"󰅇"; text:"Send clipboard"; foreground:root.foreground; fontFamily:root.fontFamily; hasCursor:root.cursorActive&&root.selectedIndex===1; onHovered:function(v){root.noteHover(v,1)}; onClicked:root.sendClipboard() }
          Button { width:parent.width; leftAlign:true; bordered:false; iconText:"󰅁"; text:"Back"; foreground:root.dim; fontFamily:root.fontFamily; hasCursor:root.cursorActive&&root.selectedIndex===2; onHovered:function(v){root.noteHover(v,2)}; onClicked:root.goBack() }
        }

        Column {
          visible: !root.quickShareMode && root.viewState === "pin"; width:parent.width; spacing:Style.space(8)
          PanelSectionHeader { text:"RECEIVER PIN"; foreground:root.foreground; fontFamily:root.fontFamily }
          Text { width:parent.width; text:"This receiver requires a PIN"; color:root.dim; font.family:root.fontFamily; font.pixelSize:Style.font.body }
          TextField {
            id: pinInput; width:parent.width; password:true; placeholderText:"PIN"; foreground:root.foreground; font.family:root.fontFamily; font.pixelSize:Style.font.body
            onAccepted: root.retryWithPin()
            Keys.onPressed: function(event) { if(event.key===Qt.Key_Escape){root.cancelPin();event.accepted=true} }
          }
          Text { visible:root.pinError!==""; width:parent.width; text:root.pinError; color:root.urgent; font.family:root.fontFamily; font.pixelSize:Style.font.body }
          Row { width:parent.width; spacing:Style.space(8)
            Button { width:(parent.width-parent.spacing)/2; text:"Cancel"; bordered:true; foreground:root.dim; onClicked:root.cancelPin() }
            Button { width:(parent.width-parent.spacing)/2; text:"Retry"; bordered:true; foreground:root.foreground; onClicked:root.retryWithPin() }
          }
        }

        Column {
          visible: !root.quickShareMode && root.viewState === "incoming_pin_settings"; width:parent.width; spacing:Style.space(8)
          Button { visible:!root.incomingPinEnabled; width:parent.width; text:"Enable PIN"; bordered:true; foreground:root.foreground; hasCursor:root.cursorActive&&root.selectedIndex===0; onHovered:function(v){root.noteHover(v,0)}; onClicked:root.beginIncomingPinEdit() }
          Row { visible:root.incomingPinEnabled; width:parent.width; spacing:Style.space(8)
            Button { width:(parent.width-parent.spacing)/2; text:"Change PIN"; bordered:true; foreground:root.foreground; hasCursor:root.cursorActive&&root.selectedIndex===0; onHovered:function(v){root.noteHover(v,0)}; onClicked:root.beginIncomingPinEdit() }
            Button { width:(parent.width-parent.spacing)/2; text:"Disable PIN"; bordered:true; foreground:root.urgent; hasCursor:root.cursorActive&&root.selectedIndex===1; onHovered:function(v){root.noteHover(v,1)}; onClicked:root.requestDisableIncomingPin() }
          }
          Button { width:parent.width; leftAlign:true; bordered:false; iconText:"󰅁"; text:"Back"; foreground:root.dim; fontFamily:root.fontFamily; hasCursor:root.cursorActive&&root.selectedIndex===(root.incomingPinEnabled?2:1); onHovered:function(v){root.noteHover(v,root.incomingPinEnabled?2:1)}; onClicked:root.goBack() }
          Text { visible:root.incomingPinError!==""; width:parent.width; text:root.incomingPinError; color:root.urgent; font.family:root.fontFamily; font.pixelSize:Style.font.body; wrapMode:Text.Wrap }
        }

        Column {
          visible: !root.quickShareMode && root.viewState === "incoming_pin_edit"; width:parent.width; spacing:Style.space(8)
          PanelSectionHeader { text:root.incomingPinEnabled?"CHANGE PIN":"ENABLE PIN"; foreground:root.foreground; fontFamily:root.fontFamily }
          Text { width:parent.width; text:"Use 1–64 letters, numbers, dot, underscore, tilde or hyphen"; color:root.dim; font.family:root.fontFamily; font.pixelSize:Style.font.body; wrapMode:Text.Wrap }
          TextField {
            id:incomingPinInput; width:parent.width; password:true; placeholderText:"New PIN"; maximumLength:64; enabled:!root.incomingPinUpdating; foreground:root.foreground; font.family:root.fontFamily; font.pixelSize:Style.font.body
            validator:RegularExpressionValidator { regularExpression:/[A-Za-z0-9._~-]{0,64}/ }
            onAccepted:root.submitIncomingPin()
            Keys.onPressed:function(event){if(event.key===Qt.Key_Escape){root.cancelIncomingPinSettings();event.accepted=true}}
          }
          Text { visible:root.incomingPinError!==""; width:parent.width; text:root.incomingPinError; color:root.urgent; font.family:root.fontFamily; font.pixelSize:Style.font.body; wrapMode:Text.Wrap }
          Row { width:parent.width; spacing:Style.space(8)
            Button { width:(parent.width-parent.spacing)/2; text:"Cancel"; bordered:true; enabled:!root.incomingPinUpdating; foreground:root.dim; onClicked:root.cancelIncomingPinSettings() }
            Button { width:(parent.width-parent.spacing)/2; text:root.incomingPinUpdating?"Saving…":"Save"; bordered:true; enabled:!root.incomingPinUpdating; foreground:root.foreground; onClicked:root.submitIncomingPin() }
          }
        }

        Column {
          visible: !root.quickShareMode && root.viewState === "incoming_pin_disable"; width:parent.width; spacing:Style.space(8)
          PanelSectionHeader { text:"DISABLE PIN"; foreground:root.foreground; fontFamily:root.fontFamily }
          Text { width:parent.width; text:"New incoming requests will no longer require a PIN."; color:root.dim; font.family:root.fontFamily; font.pixelSize:Style.font.body; wrapMode:Text.Wrap }
          Text { visible:root.incomingPinError!==""; width:parent.width; text:root.incomingPinError; color:root.urgent; font.family:root.fontFamily; font.pixelSize:Style.font.body; wrapMode:Text.Wrap }
          Row { width:parent.width; spacing:Style.space(8)
            Button { width:(parent.width-parent.spacing)/2; text:"Cancel"; bordered:true; enabled:!root.incomingPinUpdating; foreground:root.dim; hasCursor:root.cursorActive&&root.selectedIndex===0; onHovered:function(v){root.noteHover(v,0)}; onClicked:root.cancelIncomingPinSettings() }
            Button { width:(parent.width-parent.spacing)/2; text:root.incomingPinUpdating?"Disabling…":"Disable"; bordered:true; enabled:!root.incomingPinUpdating; foreground:root.urgent; hasCursor:root.cursorActive&&root.selectedIndex===1; onHovered:function(v){root.noteHover(v,1)}; onClicked:root.confirmDisableIncomingPin() }
          }
        }

        Column {
          visible: !root.quickShareMode && root.viewState === "incoming" && root.incoming; width:parent.width; spacing:Style.space(8)
          Text { width:parent.width; textFormat:Text.PlainText; text:root.incoming ? root.incoming.sender+" wants to send" : ""; color:root.foreground; font.family:root.fontFamily; font.pixelSize:Style.font.title; font.bold:true }
          Text { width:parent.width; textFormat:Text.PlainText; text:root.incoming ? Model.incomingSummary(root.incoming.files)+" · "+Model.formatBytes(root.incoming.total) : ""; color:root.dim; font.family:root.fontFamily; font.pixelSize:Style.font.body; elide:Text.ElideRight }
          Text { visible:root.incomingQueue.length>1; width:parent.width; text:(root.incomingQueue.length-1)+(root.incomingQueue.length===2 ? " more request" : " more requests"); color:root.dim; font.family:root.fontFamily; font.pixelSize:Style.font.body }
          Row { width:parent.width; spacing:Style.space(8)
            Button { width:(parent.width-parent.spacing)/2; text:"Decline"; foreground:root.urgent; bordered:true; hasCursor:root.cursorActive&&root.selectedIndex===0; onHovered:function(v){root.noteHover(v,0)}; onClicked:root.declineIncoming() }
            Button { width:(parent.width-parent.spacing)/2; text:"Accept"; foreground:root.foreground; bordered:true; hasCursor:root.cursorActive&&root.selectedIndex===1; onHovered:function(v){root.noteHover(v,1)}; onClicked:root.acceptIncoming() }
          }
        }

        Column {
          visible: !root.quickShareMode && (root.viewState==="sending"||root.viewState==="receiving"); width:parent.width; spacing:Style.space(8)
          PanelSectionHeader { text:root.viewState==="sending" ? "SENDING" : "RECEIVING"; foreground:root.foreground; fontFamily:root.fontFamily }
          Text { width:parent.width; textFormat:Text.PlainText; text:root.transferName; color:root.foreground; font.family:root.fontFamily; font.pixelSize:Style.font.title; font.bold:true; elide:Text.ElideMiddle }
          Rectangle { width:parent.width; height:Style.space(4); radius:height/2; color:Qt.darker(root.foreground,2.2); Rectangle { width:parent.width*Math.max(0,Math.min(1,root.progress)); height:parent.height; radius:height/2; color:root.foreground; Behavior on width { NumberAnimation { duration:120 } } } }
          Text { text:Math.round(root.progress*100)+"% · "+(root.viewState==="sending"?"to ":"from ")+root.transferPeer; color:root.dim; font.family:root.fontFamily; font.pixelSize:Style.font.body }
          Button { visible:root.viewState==="sending"; text:"Cancel"; bordered:true; foreground:root.urgent; hasCursor:root.cursorActive; onClicked:root.cancelOutgoing() }
        }

        Column {
          visible: !root.quickShareMode && (root.viewState==="success"||root.viewState==="error"); width:parent.width; spacing:Style.space(8)
          Text { width:parent.width; textFormat:Text.PlainText; text:root.viewState==="success" ? root.statusText : root.errorText; wrapMode:Text.Wrap; color:root.viewState==="error"?root.urgent:root.foreground; font.family:root.fontFamily; font.pixelSize:Style.font.title; font.bold:true }
          Text { visible:root.viewState==="success"; width:parent.width; textFormat:Text.PlainText; text:root.transferPeer!=="" ? (root.statusText==="Sent"?"to ":"from ")+root.transferPeer : ""; wrapMode:Text.Wrap; color:root.dim; font.family:root.fontFamily; font.pixelSize:Style.font.body }
          Button { text:"Done"; bordered:true; foreground:root.foreground; hasCursor:root.cursorActive; onClicked:root.finishTerminal() }
        }

        Column {
          visible: !root.quickShareMode && root.viewState === "device_name"
          width:parent.width; spacing:Style.space(6)
          PanelSectionHeader { text:"DEVICE NAME"; foreground:root.foreground; fontFamily:root.fontFamily }
          Text {
            width:parent.width; textFormat:Text.PlainText; wrapMode:Text.Wrap
            text:"Nearby devices see this machine as \u201c" + root.advertisedName + "\u201d."
            color:root.dim; font.family:root.fontFamily; font.pixelSize:Style.font.body
          }
          Button {
            width:parent.width; leftAlign:true; bordered:root.deviceNameMode==="hostname"
            iconText:"\u{f0322}"; text:"Hostname \u00b7 " + (root.systemHostname !== "" ? root.systemHostname : "unknown")
            foreground:root.deviceNameMode==="hostname"?root.foreground:root.dim; fontFamily:root.fontFamily
            hasCursor:root.cursorActive&&root.selectedIndex===0
            onHovered:function(v){root.noteHover(v,0)}; onClicked:root.chooseNameMode("hostname")
          }
          Button {
            width:parent.width; leftAlign:true; bordered:root.deviceNameMode==="generated"
            iconText:"\u{f0674}"; text:"Generated \u00b7 " + root.generatedPreview
            foreground:root.deviceNameMode==="generated"?root.foreground:root.dim; fontFamily:root.fontFamily
            hasCursor:root.cursorActive&&root.selectedIndex===1
            onHovered:function(v){root.noteHover(v,1)}; onClicked:root.chooseNameMode("generated")
          }
          Button {
            width:parent.width; leftAlign:true; bordered:root.deviceNameMode==="custom"
            iconText:"\u{f03eb}"; text:"Custom"
            foreground:root.deviceNameMode==="custom"?root.foreground:root.dim; fontFamily:root.fontFamily
            hasCursor:root.cursorActive&&root.selectedIndex===2
            onHovered:function(v){root.noteHover(v,2)}; onClicked:root.chooseNameMode("custom")
          }
          TextField {
            id: nameInput
            visible: root.deviceNameMode === "custom"
            width:parent.width; placeholderText:"Name shown to other devices"; maximumLength:32
            onVisibleChanged: if (visible && text === "") text = root.customDeviceName
            foreground:root.foreground; font.family:root.fontFamily; font.pixelSize:Style.font.body
            onAccepted: root.submitCustomName()
            Keys.onPressed: function(event) { if(event.key===Qt.Key_Escape){root.closeDeviceName();event.accepted=true} }
          }
          Text {
            width:parent.width; textFormat:Text.PlainText; wrapMode:Text.Wrap
            text:"Changing the name restarts the receiver for a moment."
            color:root.dim; font.family:root.fontFamily; font.pixelSize:Style.font.body
          }
          Button {
            width:parent.width; leftAlign:true; bordered:false; iconText:"\u{f0141}"; text:"Back"
            foreground:root.dim; fontFamily:root.fontFamily
            hasCursor:root.cursorActive&&root.selectedIndex===4
            onHovered:function(v){root.noteHover(v,4)}; onClicked:root.closeDeviceName()
          }
        }

        Column {
          visible: !root.quickShareMode && root.viewState==="text"; width:parent.width; spacing:Style.space(8)
          PanelSectionHeader { text:"RECEIVED TEXT"; foreground:root.foreground; fontFamily:root.fontFamily }
          Text { width:parent.width; textFormat:Text.PlainText; text:root.incomingText; wrapMode:Text.Wrap; maximumLineCount:6; elide:Text.ElideRight; color:root.foreground; font.family:root.fontFamily; font.pixelSize:Style.font.body }
          Row { width:parent.width; spacing:Style.space(8)
            Button { width:(parent.width-parent.spacing)/2; text:"Copy"; iconText:"󰆏"; bordered:true; foreground:root.foreground; hasCursor:root.cursorActive&&root.selectedIndex===0; onHovered:function(v){root.noteHover(v,0)}; onClicked:{root.copyReceivedText()} }
            Button { width:(parent.width-parent.spacing)/2; text:"Done"; bordered:true; foreground:root.foreground; hasCursor:root.cursorActive&&root.selectedIndex===1; onHovered:function(v){root.noteHover(v,1)}; onClicked:root.finishText() }
          }
        }

        // ---------------------------------------------------------------
        // Quick Share
        //
        // Reads from the `qs` CLI rather than a resident helper, so this pane
        // has no receiver toggle and no incoming states: `qs receive` cannot
        // ask the panel for consent off a TTY, it can only auto-accept. Until
        // the CLI can report an incoming request as an event, offering a
        // receive switch here would mean accepting every transfer on the LAN
        // unattended, so the pane sends only and says so.
        // ---------------------------------------------------------------
        Column {
          visible: root.quickShareMode && root.qsViewState === "nearby"
          width: parent.width; spacing: Style.space(6)

          PanelSectionHeader { text: root.qsAvailable ? "DEVICES" : "SETUP"; foreground:root.foreground; fontFamily:root.fontFamily }

          // Two different not-availables, and the pane says which: a missing
          // helper can be built, a radio that is down cannot, and only the
          // first is worth offering an install for.
          Column {
            visible: !root.qsAvailable && root.qsChecked
            width: parent.width; spacing: Style.space(6)
            Text {
              width:parent.width; textFormat:Text.PlainText; wrapMode:Text.Wrap
              text: root.qsMissingDeps.length > 0
                ? "Quick Share needs a helper this plugin does not ship. It is built from source on this machine."
                : (root.qsRadioReason !== ""
                  ? "Quick Share cannot run yet: " + root.qsRadioReason + "."
                  : "Quick Share cannot run yet on this machine.")
              color:root.dim; font.family:root.fontFamily; font.pixelSize:Style.font.body
            }
            Text {
              visible: root.qsMissingDeps.length > 0
              width:parent.width; textFormat:Text.PlainText; wrapMode:Text.Wrap
              text:"Missing: " + root.qsMissingDeps.join(", ")
              color:root.foreground; font.family:root.fontFamily; font.pixelSize:Style.font.body
            }
            Button {
              visible: root.qsMissingDeps.length > 0
              width:parent.width; bordered:true; iconText:"󰇚"; text:"Install dependencies"
              tooltipText:"Opens a terminal to install what is missing"
              foreground:root.foreground; fontFamily:root.fontFamily
              hasCursor:root.cursorActive && root.selectedIndex === 0
              onHovered:function(v){root.noteHover(v,0)}
              onClicked:root.installDependencies()
            }
          }

          Text {
            visible: root.qsAvailable && root.qsDevices.length === 0
            width:parent.width; textFormat:Text.PlainText; wrapMode:Text.Wrap
            text: root.qsScanning ? "Searching\u2026" : (root.qsErrorText !== "" ? root.qsErrorText : "No devices nearby")
            color: root.qsErrorText !== "" ? root.urgent : root.dim
            font.family:root.fontFamily; font.pixelSize:Style.font.body
            topPadding:Style.space(12); bottomPadding:Style.space(12)
          }

          Repeater {
            model: root.qsAvailable ? root.qsDevices : []
            Button {
              required property var modelData; required property int index
              width:parent.width; leftAlign:true; bordered:false
              iconText: Model.quickShareIconFor(modelData.deviceType)
              text: modelData.alias
              foreground:root.foreground; fontFamily:root.fontFamily
              hasCursor:root.cursorActive && root.selectedIndex === index
              onHovered:function(v){root.noteHover(v,index)}
              onClicked:root.qsChooseDevice(index)
            }
          }

          Button {
            visible: root.qsAvailable
            width:parent.width; bordered:false; iconText:"󰑐"
            text: "Search for devices"
            tooltipText:"Quick Share only lists devices while it is looking"
            enabled: !root.qsScanning
            foreground:root.foreground; fontFamily:root.fontFamily
            hasCursor:root.cursorActive && root.selectedIndex === root.qsDevices.length
            onHovered:function(v){root.noteHover(v,root.qsDevices.length)}
            onClicked:root.qsScan()
          }

          Button {
            width:parent.width; bordered:false; iconText:"󰌵"; text:"Firewall rules"
            tooltipText:"Open the ports both protocols need"
            foreground:root.dim; fontFamily:root.fontFamily
            onClicked:root.configureFirewall()
          }
        }

        Column {
          visible: root.quickShareMode && root.qsViewState === "target"
          width:parent.width; spacing:Style.space(6)
          PanelSectionHeader { text:"SEND"; foreground:root.foreground; fontFamily:root.fontFamily }
          Button {
            width:parent.width; leftAlign:true; iconText:"󰈔"; text:"Send files"
            foreground:root.foreground; fontFamily:root.fontFamily
            hasCursor:root.cursorActive&&root.selectedIndex===0
            onHovered:function(v){root.noteHover(v,0)}; onClicked:root.qsSelectFiles()
          }
          // No clipboard row: `qs send` takes file paths only. rqs_lib can
          // carry text, but the CLI exposes no way to hand it any.
          Text {
            width:parent.width; textFormat:Text.PlainText; wrapMode:Text.Wrap
            text:"Quick Share sends files only. Use LocalSend for clipboard text."
            color:root.dim; font.family:root.fontFamily; font.pixelSize:Style.font.body
          }
          Button {
            width:parent.width; leftAlign:true; bordered:false; iconText:"󰅁"; text:"Back"
            foreground:root.dim; fontFamily:root.fontFamily
            hasCursor:root.cursorActive&&root.selectedIndex===1
            onHovered:function(v){root.noteHover(v,1)}; onClicked:root.qsBack()
          }
        }

        Column {
          visible: root.quickShareMode && root.qsViewState === "sending"
          width:parent.width; spacing:Style.space(8)
          PanelSectionHeader { text:"SENDING"; foreground:root.foreground; fontFamily:root.fontFamily }
          Text { width:parent.width; textFormat:Text.PlainText; text:root.qsTransferName; color:root.foreground; font.family:root.fontFamily; font.pixelSize:Style.font.title; font.bold:true; elide:Text.ElideMiddle }

          // The confirmation code the phone shows. `qs` prints it once, on
          // stderr, in the line it emits while waiting for the other side.
          Column {
            visible: root.qsTransferPin !== ""
            width:parent.width; spacing:Style.space(2)
            Text { width:parent.width; text:"Confirm this code on " + root.qsTransferPeer; color:root.dim; font.family:root.fontFamily; font.pixelSize:Style.font.body; wrapMode:Text.Wrap }
            Text { width:parent.width; text:root.qsTransferPin; color:root.foreground; font.family:root.fontFamily; font.pixelSize:Style.font.display; font.bold:true }
          }

          // Ten buckets, not a smooth bar: off a TTY `qs` reports progress
          // every 10% rather than continuously, so animating between the
          // steps is the honest way to show it.
          Rectangle {
            width:parent.width; height:Style.space(4); radius:height/2; color:Qt.darker(root.foreground,2.2)
            Rectangle { width:parent.width*Math.max(0,Math.min(1,root.qsProgress)); height:parent.height; radius:height/2; color:root.foreground; Behavior on width { NumberAnimation { duration:220 } } }
          }
          Text { text:Math.round(root.qsProgress*100)+"% \u00b7 to "+root.qsTransferPeer; color:root.dim; font.family:root.fontFamily; font.pixelSize:Style.font.body }
          Button {
            width:parent.width; text:"Cancel"; bordered:true; foreground:root.urgent
            hasCursor:root.cursorActive&&root.selectedIndex===0
            onHovered:function(v){root.noteHover(v,0)}; onClicked:root.qsCancel()
          }
        }

        Column {
          visible: root.quickShareMode && (root.qsViewState === "success" || root.qsViewState === "error")
          width:parent.width; spacing:Style.space(8)
          Text {
            width:parent.width; textFormat:Text.PlainText; wrapMode:Text.Wrap
            text: root.qsViewState === "success" ? "Sent" : root.qsErrorText
            color: root.qsViewState === "error" ? root.urgent : root.foreground
            font.family:root.fontFamily; font.pixelSize:Style.font.title; font.bold:true
          }
          Text {
            visible: root.qsViewState === "success" && root.qsTransferPeer !== ""
            width:parent.width; textFormat:Text.PlainText; text:"to "+root.qsTransferPeer
            color:root.dim; font.family:root.fontFamily; font.pixelSize:Style.font.body
          }
          Button {
            width:parent.width; text:"Done"; bordered:true; foreground:root.foreground
            hasCursor:root.cursorActive&&root.selectedIndex===0
            onHovered:function(v){root.noteHover(v,0)}; onClicked:root.qsFinish()
          }
        }
      }
    }
  }

  // The text goes out as an argument rather than through stdin: none of it is
  // secret, and it keeps this independent of clipboardWriter, which holds
  // mid-transfer state the update row must not disturb.
  Process {
    id: textCopier
    property bool launched: false
    property string payload: ""
    command: ["wl-copy", textCopier.payload]
    running: false
    onStarted: textCopier.launched=true
    onRunningChanged: if (!running && !textCopier.launched) root.copyNote="wl-copy is required to copy"
    onExited: function(code) { root.copyNote = code===0 ? "Copied to clipboard" : "wl-copy is required to copy" }
  }

  Process {
    id: clipboardWriter
    property bool launched: false
    command: ["wl-copy"]
    running: false
    stdinEnabled: true
    onStarted: { clipboardWriter.launched=true; write(root.incomingText); stdinEnabled=false }
    onRunningChanged: if (!running && !clipboardWriter.launched && root.viewState==="text") root.failWith("wl-copy is required to copy received text")
    onExited: function(code) { stdinEnabled=true; if(root.viewState!=="text")return; if(code===0){root.noteTextCopied()} else root.failWith("wl-copy is required to copy received text") }
  }

  // Quick Share's own chooser. Separate from `picker` because the two panes
  // can each hold a target and neither should be able to hand a path to the
  // other's engine.
  Process {
    id: qsPicker
    property bool launched: false
    command: ["omarchy-file-select","--title","Send with Quick Share","--multiple"]
    running: false
    stdout: StdioCollector { id: qsPickerOutput; waitForEnd: true }
    onStarted: qsPicker.launched = true
    onRunningChanged: if (!running && !qsPicker.launched) { if (root.qs) root.qs.failWith("The file chooser could not be started") }
    onExited: function(code) {
      if (code > 1) { if (root.qs) root.qs.failWith("The file chooser did not open"); return }
      if (code !== 0 || !root.qsSelected) return
      var paths = String(qsPickerOutput.text || "").split("\n").filter(function(v){ return v.trim() !== "" })
      if (paths.length && root.qs) root.qs.sendFiles(paths)
    }
  }

  // Both of these need a terminal: one runs pacman and cargo, the other runs
  // ufw, and a password prompt has to land somewhere the user can answer it.
  // Neither script is ever run with elevated privileges from here.
  Process {
    id: depsInstaller
    command: ["bash","-c","if command -v omarchy-launch-floating-terminal-with-presentation >/dev/null 2>&1; then omarchy-launch-floating-terminal-with-presentation \"bash '" + root.qsScriptDirQuoted + "/dependencies.sh' --install\"; else xdg-terminal-exec bash '" + root.qsScriptDirQuoted + "/dependencies.sh' --install; fi"]
    running: false
    // The installer runs detached in its own terminal, so this exit says the
    // launcher returned, not that anything was installed. Re-probing is what
    // turns the pane back on, and it is cheap.
    onExited: function(code) { depsRecheck.restart() }
  }
  Process {
    id: firewallSetup
    command: ["bash","-c","if command -v omarchy-launch-floating-terminal-with-presentation >/dev/null 2>&1; then omarchy-launch-floating-terminal-with-presentation \"bash '" + root.qsScriptDirQuoted + "/setup_firewall.sh'\"; else xdg-terminal-exec bash '" + root.qsScriptDirQuoted + "/setup_firewall.sh'; fi"]
    running: false
  }
  // Polls only while the popup is open and only after an install was started,
  // so a build that takes ten minutes still flips the pane over when it lands.
  Timer {
    id: depsRecheck
    interval: 4000; repeat: true
    running: false
    property int ticks: 0
    onRunningChanged: if (running) ticks = 0
    onTriggered: {
      ticks++
      if (root.qs) root.qs.refreshDependencies()
      if (root.qsAvailable || ticks > 225) stop()
    }
  }
}
