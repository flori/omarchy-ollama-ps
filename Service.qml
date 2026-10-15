import QtQuick
import Quickshell
import Quickshell.Io
import "OllamaModel.js" as OllamaModel
import "OllamaState.js" as OllamaState

Item {
  id: root

  // ── Widget state ──
  property var shell: null
  property string state: "checking"
  property var servers: []
  property int totalLoadedModelCount: 0
  property double totalAggregateVramBytes: 0
  property bool anyOnline: false
  property string errorText: ""
  property string actionErrorText: ""
  property string pendingServerUrl: ""
  property string statusErrorKind: ""
  property string actionErrorKind: ""
  property double lastSuccessfulRefreshMs: 0
  property double lastRefreshStartedMs: 0
  property double lastRefreshCompletedMs: 0
  property bool lastRefreshSucceeded: false
  property int refreshCompletionSerial: 0
  property bool refreshing: false
  property string localApiStatus: "checking"
  property string lastErrorKind: ""
  property bool busy: false
  property int failureCount: 0
  property string pendingModel: ""
  property bool pendingRefresh: false
  readonly property string feedbackText: OllamaState.feedbackText(root)
  // ── Transport invocation ──
  // ollama-ps.sh is the interpreter-probe wrapper: it resolves ruby itself
  // (asdf/rbenv/mise shims → distro) and execs ollama-ps.rb. QML only hands
  // over HOME (the wrapper rebuilds PATH from it) plus the OLLAMA_* config.
  readonly property string scriptPath: decodeURIComponent(Qt.resolvedUrl("ollama-ps.sh").toString().replace(/^file:\/\//, ""))
  // Derive $HOME from the plugin location (~/.config/omarchy/plugins/flori.ollama-ps).
  readonly property string homePath: {
    var marker = "/.config/omarchy/plugins/flori.ollama-ps/"
    var idx = scriptPath.indexOf(marker)
    return idx !== -1 ? scriptPath.slice(0, idx) : ""
  }
  readonly property var processEnvironment: ({
    HOME: homePath,
    LANG: "C.UTF-8",
    LC_ALL: "C.UTF-8",
    OLLAMA_SERVERS: OllamaModel.stringifyServers(configuredServers),
    OLLAMA_PS_MAX_MODELS: String(maxDisplayedModels)
  })
  // ── Settings & poll cadence ──
  property int refreshIntervalSec: 15
  property int maxDisplayedModels: 12
  property bool compactMode: false
  property var configuredServers: ({})
  property var _configurations: ({})
  property string _configurationSource: ""
  readonly property int nextPollInterval: state === "unavailable"
    ? Math.min(refreshIntervalSec * 1000 * Math.pow(2, Math.min(failureCount, 3)), 300000)
    : refreshIntervalSec * 1000

  // ── Functions ──
  function plain(value, maximum) { return OllamaModel.plainText(value, maximum) }
  // Deep-equality; servers compared via JSON round-trip.
  function sameSettings(left, right) {
    return left && right && left.refreshIntervalSec === right.refreshIntervalSec
      && left.maxDisplayedModels === right.maxDisplayedModels && left.compactMode === right.compactMode
      && JSON.stringify(left.servers) === JSON.stringify(right.servers)
  }
  // Lexically first registered source wins (stable across monitors).
  function selectedConfiguration() {
    var keys = Object.keys(_configurations).sort()
    return keys.length > 0 ? { source: keys[0], settings: _configurations[keys[0]] } : null
  }
  // Diff current vs selected settings; apply and refresh if changed.
  function applyConfiguration() {
    var selected = selectedConfiguration()
    var next = selected ? selected.settings : OllamaModel.normalizeSettings({})
    var changed = refreshIntervalSec !== next.refreshIntervalSec || maxDisplayedModels !== next.maxDisplayedModels || compactMode !== next.compactMode
      || JSON.stringify(configuredServers) !== JSON.stringify(next.servers)
    _configurationSource = selected ? selected.source : ""
    if (!changed) return false
    refreshIntervalSec = next.refreshIntervalSec
    maxDisplayedModels = next.maxDisplayedModels
    compactMode = next.compactMode
    configuredServers = next.servers
    if (pollTimer.running) pollTimer.restart()
    Qt.callLater(function() { root.refresh() })
    return true
  }
  // Each bar registers rather than overwriting the singleton. The stable,
  // lexical source selection prevents monitor instances from flapping it.
  function configure(settings, sourceId) {
    var source = String(sourceId || "default")
    var nextSettings = OllamaModel.normalizeSettings(settings)
    var current = _configurations[source]
    if (sameSettings(current, nextSettings)) return false
    var next = ({})
    for (var key in _configurations) next[key] = _configurations[key]
    next[source] = nextSettings
    _configurations = next
    return applyConfiguration()
  }
  function unconfigure(sourceId) {
    var source = String(sourceId || "default")
    if (!_configurations[source]) return false
    var next = ({})
    for (var key in _configurations) if (key !== source) next[key] = _configurations[key]
    _configurations = next
    return applyConfiguration()
  }

  // Start status process; supersede any running one to prevent overlap.
  function refresh() {
    if (busy) return false
    if (status.running) {
      pendingRefresh = true
      status.superseded = true
      refreshing = true
      terminate(status, statusKill)
      return true
    }
    status.outputText = ""
    status.expected = true
    status.timedOut = false
    status.superseded = false
    refreshing = true
    lastRefreshStartedMs = Date.now()
    statusDeadline.restart()
    status.running = true
    return true
  }

  function unload(name, serverUrl) {
    if (!OllamaState.beginUnload(root, name, serverUrl, action.running)) return false
    action.outputText = ""
    action.expected = true
    action.timedOut = false
    action.command = [scriptPath, "unload", pendingModel, pendingServerUrl]
    actionDeadline.restart()
    action.running = true
    return true
  }

  function applyStatus(output, completedAt) {
    var result = OllamaModel.parseResult(output, "status")
    if (result.ok !== true) {
      var isTimeout = OllamaModel.classifyErrorKind(result, "status_error") === "operation_timeout"
      return OllamaState.applyServers(root, {
        state: isTimeout ? "idle" : "unavailable",
        servers: isTimeout ? root.servers : [],
        totalLoadedModelCount: isTimeout ? root.totalLoadedModelCount : 0,
        totalAggregateVramBytes: isTimeout ? root.totalAggregateVramBytes : 0,
        anyOnline: isTimeout ? root.anyOnline : false,
        error: OllamaModel.errorFor(result, "Ollama PS request failed."),
        kind: OllamaModel.classifyErrorKind(result, "status_error")
      }, completedAt)
    }
    var next = OllamaModel.parseServers(result)
    return OllamaState.applyServers(root, {
      state: next.state, servers: next.servers,
      totalLoadedModelCount: next.totalLoadedModelCount,
      totalAggregateVramBytes: next.totalAggregateVramBytes,
      anyOnline: next.anyOnline, error: next.error,
      kind: next.state === "unavailable" ? "invalid_data" : ""
    }, completedAt)
  }

  // Process never started (e.g. ruby missing) → emit missing_dependency.
  function recoverStatusStart() {
    if (status.running || !status.expected) return
    status.expected = false
    var completedAt = Date.now()
    var output = '{"ok":false,"operation":"status","kind":"missing_dependency","error":"Missing dependency: ruby is required to run Ollama PS."}'
    lastRefreshSucceeded = applyStatus(output, completedAt)
    lastRefreshCompletedMs = completedAt
    refreshCompletionSerial += 1
    refreshing = false
    pollTimer.restart()
    if (pendingRefresh) pendingRefresh = false
  }

  // Action process never started → clear busy, re-poll.
  function recoverActionStart() {
    if (action.running || !action.expected) return
    action.expected = false
    OllamaState.failUnloadStart(root)
    refresh()
  }

  function terminate(process, killTimer) {
    if (!process.running) return
    process.terminating = true
    process.running = false
    killTimer.restart()
  }

  function destroyProcess(process) {
    if (!process.running) return
    process.signal(15)
  }

  function shutdown() {
    pendingRefresh = false
    pollTimer.stop()
    statusDeadline.stop()
    statusKill.stop()
    actionDeadline.stop()
    actionKill.stop()
    destroyProcess(status)
    destroyProcess(action)
  }

  // ── Processes ──
  // Status: concurrent fan-out to all servers via ollama-ps.rb.
  Process {
    id: status
    command: [root.scriptPath, "status"]
    clearEnvironment: true
    environment: root.processEnvironment
    property string outputText: ""
    property bool expected: false
    property bool timedOut: false
    property bool terminating: false
    property bool superseded: false
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: function() { status.outputText = text }
    }
    onRunningChanged: if (!running && expected) Qt.callLater(root.recoverStatusStart)
    onExited: function() {
      statusDeadline.stop()
      statusKill.stop()
      status.expected = false
      status.terminating = false
      var wasSuperseded = status.superseded
      status.superseded = false
      if (!wasSuperseded) {
        if (status.timedOut) status.outputText = '{"ok":false,"operation":"status","kind":"operation_timeout","error":"The Ollama request timed out."}'
        var completedAt = Date.now()
        root.lastRefreshSucceeded = root.applyStatus(status.outputText, completedAt)
        root.lastRefreshCompletedMs = completedAt
        root.refreshCompletionSerial += 1
        root.refreshing = false
        pollTimer.restart()
      }
      status.timedOut = false
      if (pendingRefresh) {
        pendingRefresh = false
        Qt.callLater(function() { root.refresh() })
      }
    }
  }

  // Action: single-server unload round-trip.
  Process {
    id: action
    command: []
    clearEnvironment: true
    environment: root.processEnvironment
    property string outputText: ""
    property bool expected: false
    property bool timedOut: false
    property bool terminating: false
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: function() { action.outputText = text }
    }
    onRunningChanged: if (!running && expected) Qt.callLater(root.recoverActionStart)
    onExited: function() {
      actionDeadline.stop()
      actionKill.stop()
      action.expected = false
      action.terminating = false
      if (action.timedOut) action.outputText = '{"ok":false,"operation":"unload","kind":"operation_timeout","error":"The Ollama request timed out."}'
      action.timedOut = false
      var result = OllamaModel.parseResult(action.outputText, "unload")
      if (result.ok !== true) {
        OllamaState.finishUnload(root, OllamaModel.errorFor(result, "The unload request failed."), OllamaModel.classifyErrorKind(result, "unload_error"))
      } else OllamaState.finishUnload(root, "", "")
      root.refresh()
    }
  }

  // ── Timers (kill ladder: deadline → terminate → SIGKILL) ──
  Timer { id: statusDeadline; interval: 10000; repeat: false; onTriggered: { status.timedOut = true; root.terminate(status, statusKill) } }
  Timer { id: statusKill; interval: 750; repeat: false; onTriggered: if (status.running) status.signal(9) }
  Timer { id: actionDeadline; interval: 5000; repeat: false; onTriggered: { action.timedOut = true; root.terminate(action, actionKill) } }
  Timer { id: actionKill; interval: 750; repeat: false; onTriggered: if (action.running) action.signal(9) }

  // Exponential backoff on failure; immediate on success.
  Timer {
    id: pollTimer
    interval: root.nextPollInterval
    repeat: false
    onTriggered: root.refresh()
  }

  // ── Lifecycle ──
  Component.onCompleted: root.refresh()
  Component.onDestruction: root.shutdown()
}
