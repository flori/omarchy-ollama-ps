const assert = require("assert")
const fs = require("fs")
const model = require("./OllamaModel.js")
const stateModel = require("./OllamaState.js")

// --- helpers to build test fixtures ---

function fixture() {
  return {
    plain: model.plainText,
    servers: [{
      name: "test", url: "http://localhost:11434", state: "online",
      version: "0.5.0", error: "",
      models: [{ actionable: true, modelId: "exact-model", displayName: "Exact model" }],
      loadedModelCount: 1, aggregateVramBytes: 4
    }],
    totalLoadedModelCount: 1,
    totalAggregateVramBytes: 4,
    state: "loaded",
    errorText: "",
    actionErrorText: "",
    statusErrorKind: "",
    actionErrorKind: "",
    lastErrorKind: "",
    lastSuccessfulRefreshMs: 0,
    localApiStatus: "available",
    failureCount: 0,
    busy: false,
    pendingModel: "",
    pendingServerUrl: ""
  }
}

function successfulOutcome() {
  return {
    state: "loaded",
    servers: [{
      name: "test", url: "http://localhost:11434", state: "online",
      version: "0.5.0", error: "",
      models: [{ actionable: true, modelId: "refreshed-model", displayName: "Refreshed model" }],
      loadedModelCount: 3, aggregateVramBytes: 96
    }],
    totalLoadedModelCount: 3,
    totalAggregateVramBytes: 96,
    anyOnline: true,
    error: ""
  }
}

function failedOutcome(message) {
  return {
    state: "unavailable",
    servers: [],
    totalLoadedModelCount: 0,
    totalAggregateVramBytes: 0,
    anyOnline: false,
    error: message,
    kind: "transport_error"
  }
}

// --- plainText / boundedInteger / canonicalModelId ---

assert.strictEqual(model.plainText(" <b>model</b>\n\u061c\u202Ename\u0000 ", 160), "model name")
assert.strictEqual(model.plainText("<img src=x>"), "")
assert.strictEqual(model.boundedInteger(999, 12, 1, 12), 12)
assert.strictEqual(model.canonicalModelId("exact-model:1"), "exact-model:1")
assert.strictEqual(model.canonicalModelId(" model"), "")
assert.strictEqual(model.canonicalModelId("x".repeat(257)), "")

// --- normalizeServers ---

assert.deepStrictEqual(model.normalizeServers({ a: "http://a:1", b: "", c: 42, d: "<b>http://d</b>" }), { a: "http://a:1", d: "http://d" })
assert.deepStrictEqual(model.normalizeServers(null), {})
assert.deepStrictEqual(model.normalizeServers(["x"]), {})
assert.deepStrictEqual(model.normalizeServers({ x: "" }), {})

// --- stringifyServers ---

assert.strictEqual(model.stringifyServers({ a: "http://a:1" }), JSON.stringify({ a: "http://a:1" }))
assert.strictEqual(model.stringifyServers({}), "{}")
assert.strictEqual(model.stringifyServers(null), "{}")
assert.strictEqual(model.stringifyServers(undefined), "{}")

// --- normalizeSettings (with servers) ---

assert.deepStrictEqual(
  model.normalizeSettings({ refreshIntervalSec: 1, maxDisplayedModels: 99, compactMode: "true", servers: { x: "http://x" } }),
  { refreshIntervalSec: 5, maxDisplayedModels: 99, compactMode: true, servers: { x: "http://x" } }
)
assert.deepStrictEqual(
  model.normalizeSettings({}),
  { refreshIntervalSec: 15, maxDisplayedModels: 12, compactMode: false, servers: {} }
)

// --- classifyErrorKind ---

assert.strictEqual(model.classifyErrorKind({ kind: "missing_dependency", error: "Missing dependency: ruby is required to run Ollama PS." }, "status_error"), "missing_dependency")
assert.strictEqual(model.classifyErrorKind({ kind: "operation_timeout" }, "status_error"), "operation_timeout")
assert.strictEqual(model.classifyErrorKind({ kind: "<b>unexpected</b>" }, "status_error"), "status_error")

// --- parseServers ---

const parsed = model.parseServers({
  ok: true, operation: "status",
  data: { servers: [
    { name: "srv1", url: "http://s1", state: "online", version: "0.5.0", models: [
      { name: "<b>safe</b>\nname", size: 9, size_vram: 2, context_length: 4096 },
      { name: "\u202E", size: 1 }
    ], loadedModelCount: 2, aggregateVramBytes: 0 },
    { name: "srv2", url: "http://s2", state: "unavailable", version: "", error: "Cannot reach.", models: [], loadedModelCount: 0, aggregateVramBytes: 0 }
  ] }
})
assert.strictEqual(parsed.state, "loaded")
assert.strictEqual(parsed.servers.length, 2)
assert.strictEqual(parsed.servers[0].name, "srv1")
assert.strictEqual(parsed.servers[0].state, "online")
assert.strictEqual(parsed.servers[0].models.length, 1) // \u202E is empty after plainText
assert.strictEqual(parsed.servers[1].name, "srv2")
assert.strictEqual(parsed.servers[1].state, "unavailable")
assert.strictEqual(parsed.servers[1].error, "Cannot reach.")
assert.strictEqual(parsed.totalLoadedModelCount, 2)
assert.strictEqual(parsed.totalAggregateVramBytes, 0)
assert.strictEqual(parsed.anyOnline, true)

// all unavailable
const allDown = model.parseServers({ ok: true, operation: "status", data: { servers: [
  { name: "a", url: "http://a", state: "unavailable", models: [], loadedModelCount: 0, aggregateVramBytes: 0, error: "timeout" },
  { name: "b", url: "http://b", state: "unavailable", models: [], loadedModelCount: 0, aggregateVramBytes: 0, error: "dns" }
] } })
assert.strictEqual(allDown.state, "unavailable")
assert.strictEqual(allDown.anyOnline, false)

// online but no models
const onlineEmpty = model.parseServers({ ok: true, operation: "status", data: { servers: [
  { name: "a", url: "http://a", state: "online", version: "1.0", models: [], loadedModelCount: 0, aggregateVramBytes: 0 }
] } })
assert.strictEqual(onlineEmpty.state, "idle")
assert.strictEqual(onlineEmpty.anyOnline, true)

// empty servers array
assert.strictEqual(model.parseServers({ ok: true, operation: "status", data: { servers: [] } }).state, "unavailable")
// invalid payload
assert.strictEqual(model.parseServers({ ok: true, data: { models: "bad" } }).state, "unavailable")
assert.strictEqual(model.parseServers(null).state, "unavailable")

// JS keeps all models (Ruby owns the display budget)
const kept = model.parseServers({ ok: true, operation: "status", data: { servers: [
  { name: "a", url: "http://a", state: "online", models: [
    { name: "m1", size_vram: 1 }, { name: "m2", size_vram: 2 }, { name: "m3", size_vram: 3 }
  ], loadedModelCount: 3, aggregateVramBytes: 6 }
] } })
assert.strictEqual(kept.servers[0].models.length, 3)
assert.strictEqual(kept.servers[0].loadedModelCount, 3)

// overlong model name
const overlong = model.parseServers({ ok: true, operation: "status", data: { servers: [
  { name: "a", url: "http://a", state: "online", models: [{ name: "x".repeat(257) }], loadedModelCount: 1, aggregateVramBytes: 0 }
] } })
assert.strictEqual(overlong.servers[0].models[0].displayName.length, 160)
assert.strictEqual(overlong.servers[0].models[0].modelId, "")
assert.strictEqual(overlong.servers[0].models[0].actionable, false)

// canonical model id preserved
const canonical = model.parseServers({ ok: true, operation: "status", data: { servers: [
  { name: "a", url: "http://a", state: "online", models: [{ name: "exact-model", action_id: "exact-model", size_vram: 12 }], loadedModelCount: 42, aggregateVramBytes: 20 }
] } })
assert.deepStrictEqual(canonical.servers[0].models[0], { name: "exact-model", displayName: "exact-model", modelId: "exact-model", actionable: true, size: 0, sizeVram: 12, context: "", expiresAt: "" })
assert.strictEqual(canonical.totalLoadedModelCount, 42)
assert.strictEqual(canonical.totalAggregateVramBytes, 20)

// --- OllamaState: beginUnload / applyServers / finishUnload ---

{
  const s = fixture()
  assert.strictEqual(stateModel.beginUnload(s, "exact-model", "http://localhost:11434", false), true)
  assert.strictEqual(s.pendingModel, "exact-model")
  assert.strictEqual(s.pendingServerUrl, "http://localhost:11434")
  stateModel.finishUnload(s, "", "")
  assert.strictEqual(s.busy, false)
}
{
  const s = fixture()
  stateModel.beginUnload(s, "exact-model", "http://localhost:11434", false)
  stateModel.finishUnload(s, "Unload rejected", "api_error")
  s.errorText = "Older status error"
  s.statusErrorKind = "transport_error"
  s.failureCount = 2
  s.lastSuccessfulRefreshMs = 3
  const outcome = successfulOutcome()
  assert.strictEqual(stateModel.applyServers(s, outcome, 10), true)
  assert.strictEqual(s.totalLoadedModelCount, 3)
  assert.strictEqual(s.totalAggregateVramBytes, 96)
  assert.strictEqual(s.state, "loaded")
  assert.strictEqual(s.localApiStatus, "available")
  assert.strictEqual(s.actionErrorText, "Unload rejected")
  assert.strictEqual(s.actionErrorKind, "api_error")
  assert.strictEqual(s.errorText, "")
  assert.strictEqual(s.statusErrorKind, "")
  assert.strictEqual(s.failureCount, 0)
  assert.strictEqual(s.lastSuccessfulRefreshMs, 10)
}
{
  const s = fixture()
  stateModel.beginUnload(s, "exact-model", "http://localhost:11434", false)
  stateModel.finishUnload(s, "Unload rejected", "api_error")
  s.failureCount = 2
  s.lastSuccessfulRefreshMs = 7
  assert.strictEqual(stateModel.applyServers(s, failedOutcome("Status unavailable"), 11), false)
  assert.strictEqual(s.actionErrorText, "Unload rejected")
  assert.strictEqual(s.errorText, "Status unavailable")
  assert.strictEqual(s.totalLoadedModelCount, 0)
  assert.strictEqual(s.totalAggregateVramBytes, 0)
  assert.strictEqual(s.state, "unavailable")
  assert.strictEqual(s.localApiStatus, "unavailable")
  assert.strictEqual(s.statusErrorKind, "transport_error")
  assert.strictEqual(s.failureCount, 3)
  assert.strictEqual(s.lastSuccessfulRefreshMs, 7)
  assert.strictEqual(stateModel.feedbackText(s), "Unload: Unload rejected\nStatus: Status unavailable")
}
{
  const s = fixture()
  s.actionErrorText = "Keep"
  s.busy = true
  assert.strictEqual(stateModel.beginUnload(s, "exact-model", "http://localhost:11434", false), false)
  s.busy = false
  // wrong URL
  assert.strictEqual(stateModel.beginUnload(s, "exact-model", "http://wrong", false), false)
  // non-actionable model
  s.servers[0].models.push({ actionable: false, modelId: "nope" })
  assert.strictEqual(stateModel.beginUnload(s, "nope", "http://localhost:11434", false), false)
  // missing model
  assert.strictEqual(stateModel.beginUnload(s, "missing", "http://localhost:11434", false), false)
}
{
  const s = fixture()
  assert.strictEqual(stateModel.beginUnload(s, "exact-model", "http://localhost:11434", false), true)
  stateModel.failUnloadStart(s)
  assert.strictEqual(s.busy, false)
  assert.strictEqual(s.pendingModel, "")
  assert.strictEqual(s.actionErrorKind, "internal_error")
  stateModel.applyServers(s, successfulOutcome(), 15)
  assert.strictEqual(s.actionErrorText, "The unload helper could not start.")
  stateModel.applyServers(s, failedOutcome("Status after start failure"), 16)
  assert.strictEqual(s.actionErrorText, "The unload helper could not start.")
  assert.strictEqual(s.errorText, "Status after start failure")
}
{
  const s = fixture()
  s.actionErrorText = "<b>" + "a".repeat(400) + "</b>"
  s.errorText = "<i>" + "s".repeat(400) + "</i>"
  const fb = stateModel.feedbackText(s)
  const [actionLine, statusLine] = fb.split("\n")
  assert.strictEqual(actionLine.length, "Unload: ".length + 300)
  assert.strictEqual(statusLine.length, "Status: ".length + 300)
}

// --- structural QML assertions ---

const serviceSource = fs.readFileSync("Service.qml", "utf8")
assert.match(serviceSource, /function configure\(settings, sourceId\)/)
assert.match(serviceSource, /function unconfigure\(sourceId\)/)
assert.match(serviceSource, /OLLAMA_SERVERS/)
assert.match(serviceSource, /stringifyServers/)
assert.match(serviceSource, /configuredServers/)
assert.match(serviceSource, /totalLoadedModelCount/)
assert.match(serviceSource, /totalAggregateVramBytes/)
assert.match(serviceSource, /anyOnline/)
assert.match(serviceSource, /pendingServerUrl/)
assert.match(serviceSource, /OllamaState\.beginUnload\(root, name, serverUrl, action\.running\)/)
assert.match(serviceSource, /OllamaModel\.parseServers/)
assert.match(serviceSource, /OllamaState\.applyServers/)
assert.match(serviceSource, /readonly property string feedbackText: OllamaState\.feedbackText\(root\)/)
// old single-server / version plumbing is gone
assert.doesNotMatch(serviceSource, /OLLAMA_URL/)
assert.doesNotMatch(serviceSource, /versionErrorKind/)
assert.doesNotMatch(serviceSource, /apiVersion/)

const widgetSource = fs.readFileSync("BarWidget.qml", "utf8")
assert.match(widgetSource, /moduleSlots/)
assert.match(widgetSource, /slotWindow\(slot\)/)
assert.match(widgetSource, /configuredServiceSource/)
assert.match(widgetSource, /servers: setting\(\"servers\", \{\}\)/)
assert.match(widgetSource, /totalLoadedModelCount/)
assert.match(widgetSource, /onlineCount/)
assert.doesNotMatch(widgetSource, /hasPrimaryModel/)
assert.doesNotMatch(widgetSource, /primaryModel/)

const panelSource = fs.readFileSync("Panel.qml", "utf8")
assert.match(panelSource, /flatModels/)
assert.match(panelSource, /serverRepeater/)
assert.match(panelSource, /ollamaService\.unload\(modelId, serverUrl\)/)
assert.doesNotMatch(panelSource, /versionFailure/)

console.log("SUCCESS: ollama-ps helper checks passed")
