// Stateless service transitions shared by QML and Node semantics tests.
function clean(state, value, limit) {
  return state && typeof state.plain === "function" ? state.plain(value, limit) : ""
}

/** Derive lastErrorKind from the most specific active error channel. */
function updateLastErrorKind(state) {
  state.lastErrorKind = state.statusErrorKind || state.actionErrorKind || ""
}

/** Validate and commit an unload target; false if busy or mismatched. */
function beginUnload(state, name, serverUrl, actionRunning) {
  if (!state || state.busy || actionRunning || typeof name !== "string" || typeof serverUrl !== "string"
      || !Array.isArray(state.servers)) return false
  var model = ""
  for (var i = 0; i < state.servers.length; i++) {
    var server = state.servers[i]
    if (!server || server.url !== serverUrl || !Array.isArray(server.models)) continue
    for (var j = 0; j < server.models.length; j++) {
      var item = server.models[j]
      if (item && item.actionable === true && item.modelId === name) {
        model = item.modelId
        break
      }
    }
    if (model !== "") break
  }
  if (model === "") return false
  state.busy = true
  state.pendingModel = model
  state.pendingServerUrl = serverUrl
  state.actionErrorText = ""
  state.actionErrorKind = ""
  updateLastErrorKind(state)
  return true
}

/** Apply a status outcome to service state; true if the outcome is healthy. */
function applyServers(state, outcome, completedAt) {
  state.servers = outcome.servers
  state.totalLoadedModelCount = outcome.totalLoadedModelCount
  state.totalAggregateVramBytes = outcome.totalAggregateVramBytes
  state.anyOnline = outcome.anyOnline
  state.state = outcome.state
  state.errorText = clean(state, outcome.error, 300)
  state.localApiStatus = outcome.state === "unavailable" ? "unavailable" : "available"
  state.statusErrorKind = outcome.state === "unavailable" ? (outcome.kind || "") : ""
  if (outcome.state !== "unavailable") state.lastSuccessfulRefreshMs = completedAt
  state.failureCount = outcome.state === "unavailable" ? state.failureCount + 1 : 0
  updateLastErrorKind(state)
  return outcome.state !== "unavailable"
}

/** Clear busy state and record the unload result (message + kind). */
function finishUnload(state, message, kind) {
  state.busy = false
  state.pendingModel = ""
  if (message) {
    state.actionErrorText = clean(state, message, 300)
    state.actionErrorKind = kind || "unload_error"
  }
  updateLastErrorKind(state)
}

/** Shorthand: finishUnload with "could not start" / internal_error. */
function failUnloadStart(state) {
  finishUnload(state, "The unload helper could not start.", "internal_error")
}

/** Combine action and status errors into a single display string. */
function feedbackText(state) {
  var action = clean(state, state.actionErrorText, 300)
  var status = clean(state, state.errorText, 300)
  if (action && status) return "Unload: " + action + "\nStatus: " + status
  return action || status
}

if (typeof module !== "undefined") {
  module.exports = {
    updateLastErrorKind: updateLastErrorKind,
    beginUnload: beginUnload,
    applyServers: applyServers,
    finishUnload: finishUnload,
    failUnloadStart: failUnloadStart,
    feedbackText: feedbackText
  }
}
