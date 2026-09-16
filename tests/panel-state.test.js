const assert = require("node:assert/strict")
const fs = require("node:fs")
const vm = require("node:vm")
const Model = require("../Model.js")

const source = fs.readFileSync(require.resolve("../Panel.qml"), "utf8")

// The bar builds one widget per monitor (Variants over Quickshell.screens).
// Anything there can only be one of belongs to the service, which the shell
// loads once. When the widget owned the helper, the second monitor's copy lost
// the race for the LocalSend port and reported a receiver that could not
// start while the first copy was holding it.
assert.equal(source.includes("omarchy-nearby-helper"), false,
  "the widget must not spawn the helper: one would be started per monitor")
assert.equal(source.includes("IpcHandler"), false,
  "the widget must not register an IPC target: one handler would be registered per monitor")
assert.match(source, /bar\.shell\.serviceFor\(manifestPluginId\)/,
  "the widget must read its state from the single service instance")
assert.match(source, /manageIpc:\s*false/,
  "the base panel's IPC handler must stay off so the service owns the target")
assert.match(source, /barIconColor:\s*root\.receiverEnabled\s*\?\s*barForeground\s*:\s*Qt\.darker\(barForeground,\s*1\.55\)/,
  "the bar icon must dim when receiver is disabled")
assert.match(source, /BarIconButton[\s\S]*?foreground:\s*root\.barIconColor/,
  "the bar icon button must use barIconColor")
assert.equal(source.includes("Qt.ImhDigitsOnly"), false,
  "the outgoing PIN prompt must accept the same text values as LocalSend")
assert.equal(source.includes("RegularExpressionValidator { regularExpression: /[0-9]*/ }"), false,
  "the outgoing PIN prompt must not silently reject non-numeric PINs")
assert.doesNotMatch(source, /id:\s*pinInput[^\n]*maximumLength:\s*32/,
  "the outgoing PIN prompt must not retain its old 32-character limit")
for (const owned of ["backendRestart", "receiverShutdownFallback", "handleEvent(", "handleBackendExit("]) {
  assert.equal(source.includes(owned), false,
    `${owned} is engine state and must not be duplicated per monitor`)
}

// Cursor position and popup focus are genuinely per monitor and stay here.
assert.match(source, /onCursorRequested\(index\)\s*\{\s*root\.selectedIndex = index\s*\}/,
  "the engine asks each view to move its own cursor rather than holding one")
assert.match(source, /onOpenedChanged[\s\S]*?if \(root\.viewState==="pin"\) pinInput\.forceActiveFocus\(\)/,
  "reopening a pending PIN prompt must restore focus to its input")
assert.match(source, /onOpenedChanged:[\s\S]*?else \{ clearSecretInputs\(\); syncOpenState\(\) \}/,
  "closing a popup must clear locally retained PIN values")
assert.match(source, /Component\.onDestruction:\s*if \(engine && viewRegistered\) engine\.viewClosed\(\)/,
  "a view torn down while open must release its claim on discovery")
assert.match(source, /viewState === "incoming_pin_settings"\) return incomingPinEnabled \? "Protection enabled" : "Protection disabled"/,
  "PIN settings must expose their state in the hero instead of repeating it in the body")
assert.match(source, /id:nearbyActions/,
  "secondary Nearby actions should share one compact row")
assert.equal(source.includes('PanelSectionHeader { text: "NEARBY"'), false,
  "the device section must not repeat the panel title")
assert.equal(source.includes('text:root.incomingPinEnabled?"PIN protection is enabled"'), false,
  "PIN settings must not repeat the state already shown in the hero")
assert.equal((source.match(/text:"Back"/g) || []).length, 4,
  "the LocalSend device actions, PIN settings, device name and Quick Share send screens each need a visible mouse exit")

assert.equal(source.includes("closeStdin"), false, "Quickshell Process does not expose closeStdin")
assert.match(source, /onStarted:\s*\{[^}]*write\(root\.incomingText\);\s*stdinEnabled=false\s*\}/,
  "clipboard writer must close stdin after writing so wl-copy can finish")
assert.match(source, /onExited:\s*function\(code\)\s*\{\s*stdinEnabled=true;/,
  "clipboard writer must re-enable stdin for the next copy")
assert.match(source, /onExited: function\(code\) \{ stdinEnabled=true; if\(root\.viewState!=="text"\)return;/,
  "late wl-copy completion must not reopen a text result after the user exits")

assert.equal(source.includes("zenity"), false,
  "files are chosen with omarchy-file-select, which Omarchy ships, rather than zenity")
assert.match(source, /command:\s*\["omarchy-file-select"/,
  "the file chooser must be omarchy-file-select")
assert.equal(/code\s*===?\s*127/.test(source), false,
  "no shell runs on our behalf, so a missing command never reports exit code 127")
// The update row retries the immutable helper selected by the checkout when
// automatic resolution cannot prepare a compatible cached binary. It keeps
// the repository and recovery command for failures the action cannot cover.
assert.match(source, /id: helperUpdate[\s\S]*?visible: root\.helperUpdateOffered/,
  "the update row must appear exactly when the engine says the helper needs one")
assert.match(source, /text: root\.helperUpdating \? "Preparing…" : \(root\.helperUpdateError!=="" \? "Try again" : "Retry helper"\)/,
  "the button must name the retry after a failure, and say it is working while it works")
assert.match(source, /enabled:!root\.helperUpdating/,
  "a second press while helper repair runs must not start a second download")
assert.match(source, /visible:root\.helperUpdateError!==""[\s\S]*?root\.updateCommand[\s\S]*?onClicked:root\.copyUpdateCommand\(\)[\s\S]*?onClicked:root\.copyRepositoryLink\(\)/,
  "a failed update must offer the command that fixes it, not only the repository link")
assert.match(source, /text:"Copy command"[^\n]*hasCursor:[^\n]*helperCopyCommandIndex[^\n]*onHovered:[^\n]*helperCopyCommandIndex/,
  "the copy-command fallback must participate in keyboard and hover navigation")
assert.match(source, /text:"Copy link"[^\n]*hasCursor:[^\n]*helperCopyLinkIndex[^\n]*onHovered:[^\n]*helperCopyLinkIndex/,
  "the copy-link fallback must participate in keyboard and hover navigation")
// Upstream's install.sh refuses a checkout whose origin is not upstream, and
// would move the tree onto an upstream tag if it did run. The fork's recovery
// path has to be one that works from inside the fork.
assert.doesNotMatch(source, /installerCommand: "[^"]*install\.sh"/,
  "the fork must not send users to upstream's installer to repair the helper")
assert.match(source, /readonly property string repositoryUrl: "https:\/\/github\.com\/t1nk333r\/omarchy-nearby-share"/,
  "the fallback link must point at the repository the installer pulls from")
assert.equal(source.includes("install.sh"), false,
  "the removed standalone installer must not remain in the panel")

// The popup used to say the same thing three times: the hero, the device
// empty-state line, and the update row all rendered the version mismatch, and
// the hero cropped its copy mid-word.
assert.match(source, /if \(!backendReady\) return statusText/,
  "the hero must show the short status, not the full error sentence")
assert.equal(source.includes("return errorText || statusText"), false,
  "the hero must not fall back to the long error text")
assert.match(source, /text: root\.helperBlocksNearby \? "HELPER" : "DEVICES"/,
  "a view owned by the helper failure must not head its section DEVICES")
assert.match(source, /visible: root\.devices\.length===0 && !root\.helperBlocksNearby/,
  "the device empty-state line must not repeat the error the update row states")
assert.equal((source.match(/root\.helperUpdateDetail/g) || []).length, 1,
  "the versions belong in one place: the engine's detail line, rendered once")

assert.match(source, /text:root\.updateCommand; elide:Text\.ElideMiddle/,
  "the Omarchy update command must elide rather than wrap")
assert.doesNotMatch(source, /text:root\.updateCommand[^\n]*WrapAnywhere/,
  "the update command must stay on one visual line")

// Every hover handler must go through noteHover. The originals only handled
// enter, so `hasCursor` stayed on the last button the pointer crossed and the
// popup showed a highlight the mouse had already left.
assert.equal((source.match(/onHovered/g) || []).length,
  (source.match(/root\.noteHover\(/g) || []).length,
  "a hover handler that does not release the cursor leaves the button lit after the pointer goes")
assert.doesNotMatch(source, /onHovered[^\n]*if\s*\(v\)\s*\{\s*root\.cursorActive=true/,
  "taking the cursor on enter without releasing it on leave is the bug this replaced")

for (const launcher of ["picker", "clipboard", "clipboardWriter", "textCopier"]) {
  assert.match(source, new RegExp(`onRunningChanged:\\s*if\\s*\\(!running && !${launcher}\\.launched`),
    `${launcher} must report a command that never launched, which Quickshell signals by ` +
    "returning running to false without an exit code")
}

for (const [failure, description] of [
  ["Clipboard is empty", "clipboard read"],
  ["wl-paste is required to read the clipboard", "missing wl-paste"],
  ["wl-copy is required to copy received text", "clipboard write"],
  ["The file chooser could not be started", "missing file chooser"],
  ["The file chooser did not open", "file chooser fault"],
]) {
  assert.match(source, new RegExp(`failWith\\("${failure.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}"\\)`),
    `${description} errors must be raised through failWith`)
}

function extractFunction(name) {
  const marker = `function ${name}`
  const start = source.indexOf(marker)
  assert.notEqual(start, -1, `Panel.qml must define ${name}`)
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
    // Comments come before the quote test on purpose: prose is allowed to hold
    // an apostrophe ("the pane's own rows"), and without this the extractor
    // reads that apostrophe as an opening string and swallows the rest of the
    // function. The Quick Share harness learned the same lesson first.
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
    if (character === '"' || character === "'") quote = character
    else if (character === "{") depth++
    else if (character === "}" && --depth === 0) return source.slice(start, index + 1)
  }
  throw new Error(`Unterminated ${name}`)
}

const functionNames = [
  "syncOpenState", "toggleReceiver", "startDiscovery", "forceFullDiscovery",
  "chooseDevice", "acceptIncoming", "declineIncoming", "finishText", "finishTerminal",
  "cancelOutgoing", "cancelPin", "retryWithPin", "failWith", "noteTextCopied", "beginOutgoing",
  "openIncomingPinSettings", "beginIncomingPinEdit", "requestDisableIncomingPin",
  "cancelIncomingPinSettings", "submitIncomingPin", "confirmDisableIncomingPin",
  "clearSecretInputs",
  "goBack", "goBackLocalSend", "selectFiles", "sendClipboard", "copyReceivedText",
  "moveCursor", "activateCursor",
  "retryHelper", "copyText", "copyUpdateCommand", "copyRepositoryLink", "noteHover",
  // device name pane
  "openDeviceName", "closeDeviceName", "chooseNameMode", "submitCustomName", "focusCustomName",
  // Quick Share pane
  "setMode", "qsScan", "qsChooseDevice", "qsBack", "qsCancel", "qsFinish",
  "qsSelectFiles", "installDependencies", "configureFirewall",
]

// Every call the view makes has to land on the shared engine, so the stub
// records rather than implements.
function stubQuickShare(calls, record) {
  return {
    available: true,
    depsChecked: true,
    missingDeps: [],
    devices: [],
    selectedDevice: null,
    viewState: "nearby",
    statusText: "",
    errorText: "",
    progress: 0,
    transferName: "",
    transferPeer: "",
    transferPin: "",
    scan: record("qs.scan"),
    chooseDevice: record("qs.chooseDevice"),
    clearTarget: record("qs.clearTarget"),
    cancelSend: record("qs.cancelSend"),
    finishTerminal: record("qs.finishTerminal"),
    sendFiles: record("qs.sendFiles"),
    refreshDependencies: record("qs.refreshDependencies"),
    failWith: record("qs.failWith"),
  }
}

function stubEngine() {
  const calls = []
  const record = name => (...args) => { calls.push([name, ...args]); return undefined }
  return {
    calls,
    mode: "localsend",
    generatedName: "Amber Otter",
    setMode: record("setMode"),
    openDeviceName: record("openDeviceName"),
    closeDeviceName: record("closeDeviceName"),
    chooseNameMode: record("chooseNameMode"),
    submitCustomName: record("submitCustomName"),
    requestCustomNameFocus: record("requestCustomNameFocus"),
    quickshare: stubQuickShare(calls, record),
    toggleReceiver: record("toggleReceiver"),
    startDiscovery: record("startDiscovery"),
    forceFullDiscovery: record("forceFullDiscovery"),
    chooseDevice: record("chooseDevice"),
    clearTarget: record("clearTarget"),
    acceptIncoming: record("acceptIncoming"),
    declineIncoming: record("declineIncoming"),
    finishText: record("finishText"),
    finishTerminal: record("finishTerminal"),
    cancelOutgoing: record("cancelOutgoing"),
    cancelPin: record("cancelPin"),
    retryWithPin: record("retryWithPin"),
    openIncomingPinSettings: record("openIncomingPinSettings"),
    beginIncomingPinEdit: record("beginIncomingPinEdit"),
    requestDisableIncomingPin: record("requestDisableIncomingPin"),
    cancelIncomingPinSettings: record("cancelIncomingPinSettings"),
    submitIncomingPin: record("submitIncomingPin"),
    confirmDisableIncomingPin: record("confirmDisableIncomingPin"),
    failWith: record("failWith"),
    noteTextCopied: record("noteTextCopied"),
    beginOutgoing: record("beginOutgoing"),
    startHelperUpdate: record("startHelperUpdate"),
    viewOpened: record("viewOpened"),
    viewClosed: record("viewClosed"),
  }
}

// The row index of the update button is a binding, not a function, so it is
// pulled out of the source and evaluated rather than restated here: a copy of
// the expression could not catch it drifting away from the order the panel
// actually draws, which is the whole point of asserting on it.
function intBindingExpression(name) {
  const match = source.match(new RegExp(
    `readonly property int ${name}:\\s*([\\s\\S]*?)(?=\\n\\s*(?:readonly property|property |//))`))
  assert.notEqual(match, null, `Panel.qml must bind ${name}`)
  return match[1].trim()
}

function panel(initial = {}) {
  const closes = []
  const engine = initial.engine === undefined ? stubEngine() : initial.engine
  const context = {
    Model,
    Qt: {callLater: callback => callback()},
    engine,
    picker: {running: false, launched: false},
    clipboard: {running: false, launched: false},
    clipboardWriter: {running: false, launched: false},
    textCopier: {running: false, launched: false, payload: ""},
    copyNote: "",
    helperUpdateOffered: false,
    helperUpdateError: "",
    updateCommand: "omarchy plugin update t1nk33r.nearby-share",
    repositoryUrl: "https://github.com/t1nk333r/omarchy-nearby-share",
    pinInput: {text: "", forceActiveFocus: () => {}},
    incomingPinInput: {text: "", forceActiveFocus: () => {}},
    keyCatcher: {forceActiveFocus: () => {}},
    close: () => closes.push(true),
    moduleName: "oma.nearby",
    settings: {},
    opened: true,
    viewRegistered: false,
    selectedIndex: 0,
    cursorActive: false,
    devices: [],
    selectedDevice: {fingerprint: "phone", alias: "Phone"},
    viewState: "target",
    receiverEnabled: true,
    backendReady: true,
    incomingPinEnabled: false,
    // Quick Share view state. Defaults keep every pre-existing test in the
    // LocalSend pane, which is the pane those tests were written against.
    quickShareMode: false,
    deviceNameMode: "hostname",
    customDeviceName: "",
    advertisedName: "luna",
    systemHostname: "luna",
    generatedPreview: "Amber Otter",
    nameInput: {text: ""},
    qsViewState: "nearby",
    qsAvailable: true,
    qsChecked: true,
    qsDevices: [],
    qsSelected: null,
    qsMissingDeps: [],
    qsScriptDir: "/tmp/nearby-share/scripts",
    qsPicker: {running: false, launched: false},
    depsInstaller: {running: false},
    firewallSetup: {running: false},
    ...initial,
  }
  if (context.qs === undefined) context.qs = engine ? engine.quickshare : null
  context.engine = engine
  for (const name of ["helperUpdateIndex", "helperCopyCommandIndex", "helperCopyLinkIndex", "qsLastIndex"]) {
    const expression = intBindingExpression(name)
    Object.defineProperty(context, name, {
      enumerable: true,
      get: () => vm.runInNewContext(`(${expression})`, context),
    })
  }
  vm.createContext(context)
  vm.runInContext(functionNames.map(extractFunction).join("\n"), context)
  context.closes = closes
  return context
}

// A failed update adds two recovery controls after the retry button. Both have
// to be reachable and activatable without a pointer.
{
  const state = panel({
    viewState: "nearby", devices: [], backendReady: false, helperUpdateOffered: true,
    helperUpdateError: "offline", selectedIndex: 0,
  })
  assert.equal(state.helperUpdateIndex, 0)
  assert.equal(state.helperCopyCommandIndex, 1)
  assert.equal(state.helperCopyLinkIndex, 2)

  state.moveCursor(0, 1)
  assert.equal(state.selectedIndex, 1)
  state.activateCursor()
  assert.equal(state.textCopier.payload, state.updateCommand)

  state.textCopier.running = false
  state.moveCursor(1, 0)
  assert.equal(state.selectedIndex, 2)
  state.activateCursor()
  assert.equal(state.textCopier.payload, state.repositoryUrl)
}

function callNames(state) {
  return state.engine.calls.map(call => call[0])
}

{
  const state = panel({viewState: "nearby", devices: [{alias: "A"}, {alias: "B"}], selectedIndex: 0})
  state.activateCursor()
  assert.deepEqual(state.engine.calls.at(-1), ["chooseDevice", 0])
  state.selectedIndex = 2
  state.activateCursor()
  assert.equal(callNames(state).at(-1), "forceFullDiscovery",
    "the entry past the last device is the rescan action")
  state.selectedIndex = -1
  state.activateCursor()
  assert.equal(callNames(state).at(-1), "toggleReceiver",
    "the cursor above the list is the receiver switch")
  state.selectedIndex = 3
  state.activateCursor()
  assert.equal(callNames(state).at(-1), "openIncomingPinSettings",
    "the entry after rescan opens incoming PIN settings")
}

// An unusable helper hides the action row, so the update button takes the
// index rescan would have had. Keyboard users have to be able to reach it:
// without it the only stop below the receiver switch is nothing at all.
{
  const state = panel({
    viewState: "nearby", devices: [], backendReady: false, helperUpdateOffered: true, selectedIndex: -1,
  })
  assert.equal(state.helperUpdateIndex, 0)
  state.moveCursor(0, 1)
  assert.equal(state.selectedIndex, 0, "the cursor must reach the update button with no devices listed")
  state.activateCursor()
  assert.equal(callNames(state).at(-1), "startHelperUpdate",
    "the keyboard must trigger the same update the button does")
  state.moveCursor(0, 3)
  assert.equal(state.selectedIndex, 0, "the update button is the last stop in the Nearby view")
}

// Usable but behind: the action row is still drawn, so the update button lands
// after it rather than on top of rescan.
{
  const state = panel({
    viewState: "nearby", devices: [{alias: "A"}], backendReady: true, helperUpdateOffered: true, selectedIndex: 1,
  })
  assert.equal(state.helperUpdateIndex, 3)
  state.activateCursor()
  assert.equal(callNames(state).at(-1), "forceFullDiscovery",
    "an offered update must not displace rescan while the helper still works")
  state.selectedIndex = 3
  state.activateCursor()
  assert.equal(callNames(state).at(-1), "startHelperUpdate")
}

// Leaving a button must put the highlight out, and moving between two must
// leave exactly one lit whichever order the enter and leave arrive in.
{
  const state = panel({viewState: "nearby", devices: [{alias: "A"}, {alias: "B"}], selectedIndex: -1})
  state.noteHover(true, 0)
  assert.equal(state.cursorActive, true)
  assert.equal(state.selectedIndex, 0)

  state.noteHover(false, 0)
  assert.equal(state.cursorActive, false, "the pointer left, so nothing may still look hovered")
  assert.equal(state.selectedIndex, 0, "the index survives so an arrow key resumes from here")

  // leave-then-enter
  state.noteHover(true, 0)
  state.noteHover(false, 0)
  state.noteHover(true, 1)
  assert.equal(state.cursorActive, true)
  assert.equal(state.selectedIndex, 1)

  // enter-then-leave: the stale leave must not put out the button the pointer
  // is now on.
  state.noteHover(true, 0)
  state.noteHover(true, 1)
  state.noteHover(false, 0)
  assert.equal(state.cursorActive, true, "a late leave from the previous button must not clear the new one")
  assert.equal(state.selectedIndex, 1)

  assert.equal(state.engine.calls.length, 0, "hovering is local to one monitor")
}

// A released cursor comes back on the first arrow key, from where the mouse
// left it rather than from the top of the list.
{
  const state = panel({viewState: "nearby", devices: [{alias: "A"}, {alias: "B"}], selectedIndex: 0})
  state.noteHover(true, 1)
  state.noteHover(false, 1)
  assert.equal(state.cursorActive, false)
  state.moveCursor(0, 1)
  assert.equal(state.cursorActive, true)
  assert.equal(state.selectedIndex, 2, "the keyboard resumes from the button the pointer last touched")
}

// No update offered: the Nearby view keeps the row order it had.
{
  const state = panel({viewState: "nearby", devices: [{alias: "A"}], selectedIndex: 0})
  assert.equal(state.helperUpdateIndex, -1)
  state.moveCursor(0, 9)
  assert.equal(state.selectedIndex, 2, "the cursor still stops on incoming PIN settings")
}

{
  const state = panel({viewState: "incoming", selectedIndex: 1})
  state.activateCursor()
  assert.equal(callNames(state).at(-1), "acceptIncoming")
  state.selectedIndex = 0
  state.activateCursor()
  assert.equal(callNames(state).at(-1), "declineIncoming")
  state.moveCursor(1, 0)
  assert.equal(state.selectedIndex, 1, "left and right must navigate a two-button action row")
}

{
  const state = panel({viewState: "sending"})
  state.activateCursor()
  assert.equal(callNames(state).at(-1), "cancelOutgoing")
}

{
  const state = panel({viewState: "success"})
  state.activateCursor()
  assert.equal(callNames(state).at(-1), "finishTerminal",
    "keyboard Done must reach the engine the same way the visual button does")
}

{
  const state = panel({viewState: "text", selectedIndex: 1})
  state.activateCursor()
  assert.equal(callNames(state).at(-1), "finishText",
    "received text must have an exit independent of wl-copy completion")
}

{
  const state = panel({viewState: "nearby", devices: [{alias: "A"}, {alias: "B"}], selectedIndex: 0})
  state.moveCursor(0, 1)
  assert.equal(state.selectedIndex, 1)
  state.moveCursor(0, 5)
  assert.equal(state.selectedIndex, 3, "the cursor stops on incoming PIN settings after rescan")
  state.moveCursor(0, -9)
  // Three controls sit above the device list, and each must be its own stop:
  // -3 the device-name cog, -2 the protocol switcher, -1 the receiver switch.
  // The ceiling has moved twice as controls were added, so this walks the whole
  // run rather than asserting a single index.
  assert.equal(state.selectedIndex, -3, "the cursor stops on the device-name cog, the topmost control")
  state.moveCursor(0, 1)
  assert.equal(state.selectedIndex, -2, "the mode switcher is a stop below the cog")
  state.moveCursor(0, 1)
  assert.equal(state.selectedIndex, -1, "the receiver switch stays reachable below the mode switcher")
  state.moveCursor(0, -1)
  assert.equal(state.selectedIndex, -2)
  state.selectedIndex = 2
  state.moveCursor(1, 0)
  assert.equal(state.selectedIndex, 3, "left and right must navigate the compact Nearby action row")
  assert.equal(state.engine.calls.length, 0, "moving a cursor is local to one monitor")
}

// The switcher is drawn only while the engine can run (deps present, radio
// ready). When it is hidden its row is a gap the walk must carry past, or the
// cursor lands on something that is not there and Enter changes panes.
{
  const state = panel({viewState: "nearby", qsAvailable: false,
    devices: [{alias: "A"}, {alias: "B"}], selectedIndex: -3})
  state.moveCursor(0, 1)
  assert.equal(state.selectedIndex, -1, "the receiver switch follows the cog, over the hidden switcher's row")
  state.moveCursor(0, -1)
  assert.equal(state.selectedIndex, -3, "and back up, skipping it again")
  assert.equal(state.engine.calls.length, 0, "still a local move")
}

{
  const state = panel({viewState: "target"})
  state.goBack()
  assert.equal(callNames(state).at(-1), "clearTarget")
  const pin = panel({viewState: "pin"})
  pin.goBack()
  assert.equal(callNames(pin).at(-1), "cancelPin")
  const incomingPin = panel({viewState: "incoming_pin_settings"})
  incomingPin.goBack()
  assert.equal(callNames(incomingPin).at(-1), "cancelIncomingPinSettings")
  const nearby = panel({viewState: "nearby"})
  nearby.goBack()
  assert.equal(nearby.closes.length, 1, "back from the root view closes this monitor's popup")
  assert.equal(nearby.engine.calls.length, 0)
}

{
  const state = panel({viewState: "incoming_pin_edit"})
  state.incomingPinInput.text = "Abc-_.~09"
  state.submitIncomingPin()
  assert.deepEqual(state.engine.calls.at(-1), ["submitIncomingPin", "Abc-_.~09"])
}

{
  const disabled = panel({viewState: "incoming_pin_settings", incomingPinEnabled: false, selectedIndex: 0})
  disabled.activateCursor()
  assert.equal(callNames(disabled).at(-1), "beginIncomingPinEdit")
  const enabled = panel({viewState: "incoming_pin_settings", incomingPinEnabled: true, selectedIndex: 1})
  enabled.activateCursor()
  assert.equal(callNames(enabled).at(-1), "requestDisableIncomingPin")
  enabled.selectedIndex = 0
  enabled.moveCursor(1, 0)
  assert.equal(enabled.selectedIndex, 1,
    "left and right must navigate the Change/Disable row")
  enabled.selectedIndex = 2
  enabled.activateCursor()
  assert.equal(callNames(enabled).at(-1), "cancelIncomingPinSettings",
    "enabled PIN settings must expose Back to keyboard users too")
  const disabledBack = panel({viewState: "incoming_pin_settings", incomingPinEnabled: false, selectedIndex: 1})
  disabledBack.activateCursor()
  assert.equal(callNames(disabledBack).at(-1), "cancelIncomingPinSettings",
    "disabled PIN settings must expose Back to keyboard users too")
  const confirmation = panel({viewState: "incoming_pin_disable", selectedIndex: 1})
  confirmation.activateCursor()
  assert.equal(callNames(confirmation).at(-1), "confirmDisableIncomingPin")
}

{
  const state = panel({viewState: "target", selectedIndex: 2})
  state.activateCursor()
  assert.equal(callNames(state).at(-1), "clearTarget",
    "device actions must expose Back to keyboard users too")
  state.selectedIndex = 0
  state.moveCursor(0, 9)
  assert.equal(state.selectedIndex, 2, "device action cursor must stop on Back")
}

{
  const state = panel()
  state.pinInput.text = "123456"
  state.retryWithPin()
  assert.deepEqual(state.engine.calls.at(-1), ["retryWithPin", "123456"],
    "the PIN is read from this monitor's field and handed to the shared engine")
}

{
  const state = panel()
  state.pinInput.text = "outgoing-secret"
  state.incomingPinInput.text = "incoming-secret"
  state.clearSecretInputs()
  assert.equal(state.pinInput.text, "")
  assert.equal(state.incomingPinInput.text, "")
}

{
  const state = panel({selectedDevice: null})
  state.selectFiles()
  state.sendClipboard()
  assert.equal(state.picker.running, false, "no chooser without a target device")
  assert.equal(state.clipboard.running, false, "no clipboard read without a target device")
  const ready = panel()
  ready.selectFiles()
  assert.equal(ready.picker.running, true)
  ready.sendClipboard()
  assert.equal(ready.clipboard.running, true)
}

{
  const state = panel({picker: {running: true, launched: true}})
  state.selectFiles()
  assert.equal(state.picker.launched, true, "a chooser already open must not be relaunched")
}

{
  // Discovery is engine state shared by every monitor, so a view registers and
  // releases its claim exactly once.
  const state = panel({opened: true, viewRegistered: false})
  state.syncOpenState()
  state.syncOpenState()
  assert.deepEqual(callNames(state), ["viewOpened"], "an open view claims discovery once")
  state.opened = false
  state.syncOpenState()
  assert.deepEqual(callNames(state), ["viewOpened", "viewClosed"])
}

{
  // The widget must not be the source of persisted settings. The bar injects
  // `settings` a tick after the widget is built (Bar.qml: onActiveItemChanged
  // -> Qt.callLater(injectProps)), so the first value a widget could report is
  // the default, not the persisted one -- which is how a persisted
  // receiverEnabled: false used to be replaced by the default on every start.
  assert.equal(source.includes("configure("), false,
    "the widget must not push settings into the engine; the engine reads shell.json")
  assert.equal(/onSettingsChanged/.test(source), false,
    "reacting to injected settings would reintroduce the widget as a config source")
}

{
  // A widget can outlive its engine across a plugin reload; it must degrade
  // rather than throw into the shell.
  const state = panel({engine: null, viewState: "target"})
  state.toggleReceiver()
  state.goBack()
  state.retryWithPin()
  state.failWith("boom")
  state.noteTextCopied()
  state.syncOpenState()
  assert.ok(true, "view actions without an engine must not throw")
}


// --- the device-name pane ----------------------------------------------------
// Rows are 0 Hostname, 1 Generated, 2 Custom, 3 the text field, 4 Back. The
// field owned no row at first, so custom mode was unusable without a mouse.
{
  const state = panel({viewState: "device_name", selectedIndex: 0})
  state.moveCursor(0, 9)
  assert.equal(state.selectedIndex, 4, "the cursor reaches Back, the last row")
  state.moveCursor(0, -9)
  assert.equal(state.selectedIndex, 0, "and stops at the first mode row")
}
{
  for (const [index, mode] of [[0, "hostname"], [1, "generated"], [2, "custom"]]) {
    const state = panel({viewState: "device_name", selectedIndex: index})
    state.activateCursor()
    assert.deepEqual(state.engine.calls.at(-1), ["chooseNameMode", mode])
  }
}
{
  const state = panel({viewState: "device_name", selectedIndex: 3})
  state.activateCursor()
  assert.deepEqual(state.engine.calls.at(-1), ["requestCustomNameFocus"],
    "row 3 focuses the field rather than acting, so custom mode works without a mouse")
}
{
  const state = panel({viewState: "device_name", selectedIndex: 4})
  state.activateCursor()
  assert.deepEqual(state.engine.calls.at(-1), ["closeDeviceName"])
}
{
  const state = panel({viewState: "device_name", selectedIndex: 2})
  state.goBackLocalSend()
  assert.deepEqual(state.engine.calls.at(-1), ["closeDeviceName"],
    "the pane is escapable without closing the popup")
}

// The cog belongs to the LocalSend hero. Firing it from the Quick Share pane
// opened a view that pane cannot render and cannot leave.
{
  const state = panel({quickShareMode: true, viewState: "nearby", selectedIndex: -3})
  state.activateCursor()
  assert.equal(state.engine.calls.some(c => c[0] === "openDeviceName"), false,
    "the name cog must not fire from the Quick Share pane")
}
{
  const state = panel({quickShareMode: false, viewState: "nearby", selectedIndex: -3})
  state.activateCursor()
  assert.deepEqual(state.engine.calls.at(-1), ["openDeviceName"],
    "but it does from the LocalSend pane")
}
assert.match(source, /trailingControl: !root\.quickShareMode && root\.viewState === "nearby"/,
  "the hero controls are gated on the pane, not on viewState alone")
assert.match(source, /root\.viewState==="device_name"&&nameInput\.activeFocus/,
  "the key catcher must yield while the name field has focus, per the UI kit contract")

console.log("panel state tests passed")

// Merge note: upstream's helper-recovery rename (updateCommand / retryHelper /
// copyUpdateCommand) is adopted, but where upstream and the fork genuinely
// disagree -- the repository URL and the plugin id in the recovery command --
// the local fork values (t1nk333r/omarchy-nearby-share, t1nk33r.nearby-share)
// are kept, along with the fork's Quick Share pane and mode-switcher cursor row.
