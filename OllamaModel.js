// API data is untrusted even when it comes from a remote Ollama service.
var MAX_TEXT = 160
var MAX_ERROR = 300
var MAX_MODEL_ID = 256
var MAX_URL = 512

/** Sanitize untrusted text: strip HTML/tags, control chars, collapse
 *  whitespace, and truncate to the given maximum (capped at MAX_ERROR). */
function plainText(value, maximum) {
  if (typeof value !== "string") return ""
  var text = value
    .replace(/<[^>]*>/g, " ")
    .replace(/[<>]/g, " ")
    .replace(/[\r\n\t]+/g, " ")
    .replace(/[\u0000-\u001f\u007f-\u009f\u061c\u200e\u200f\u202a-\u202e\u2066-\u2069]/g, " ")
    .replace(/\s+/g, " ")
    .trim()
  return text.slice(0, Math.max(0, Math.min(Number(maximum) || 0, MAX_ERROR)))
}

/** Coerce to a clamped integer in [minimum, maximum]; return fallback if
 *  the input is not a finite number. */
function boundedInteger(value, fallback, minimum, maximum) {
  var number = Number(value)
  if (!isFinite(number)) return fallback
  return Math.max(minimum, Math.min(maximum, Math.floor(number)))
}

/** True for a non-null, non-array object. */
function isPlainObject(value) {
  return !!value && typeof value === "object" && !Array.isArray(value)
}

/** Sanitize the configured { name: url } server map for display and transport. */
function normalizeServers(value) {
  if (!isPlainObject(value)) return {}
  var out = {}
  for (var key in value) {
    if (!Object.prototype.hasOwnProperty.call(value, key)) continue
    var url = plainText(value[key], MAX_URL)
    if (url !== "") out[key] = url
  }
  return out
}

/** Serialize the server map as JSON for the OLLAMA_SERVERS env var. */
function stringifyServers(servers) {
  try {
    return JSON.stringify(isPlainObject(servers) ? servers : {})
  } catch (e) {
    return "{}"
  }
}

/** Clamp all settings fields to valid ranges; return a normalized object. */
function normalizeSettings(settings) {
  settings = isPlainObject(settings) ? settings : ({})
  return {
    refreshIntervalSec: boundedInteger(settings.refreshIntervalSec, 15, 5, 300),
    maxDisplayedModels: Math.max(1, Math.floor(Number(settings.maxDisplayedModels) || 12)),
    compactMode: settings.compactMode === true || settings.compactMode === "true" || settings.compactMode === 1 || settings.compactMode === "1",
    servers: normalizeServers(settings.servers)
  }
}

/** Whitelist the transport error kind; return fallback if unrecognized. */
function classifyErrorKind(result, fallback) {
  var kind = plainText(result && result.kind, 80)
  var allowed = ["unsafe_endpoint", "transport_error", "response_too_large", "operation_timeout", "invalid_data", "invalid_request", "internal_error", "api_error", "missing_dependency"]
  return allowed.indexOf(kind) !== -1 ? kind : fallback
}

/** Non-negative finite number, or 0. */
function safeNumber(value) {
  var number = Number(value)
  return isFinite(number) && number >= 0 ? number : 0
}

/** Context length as a bounded display string, or "" if absent. */
function safeContext(value) {
  var number = safeNumber(value)
  return number > 0 ? String(Math.min(Math.floor(number), 10000000)) : ""
}

/** Accept a model ID only if it survives sanitization unchanged (exact). */
function canonicalModelId(value) {
  if (typeof value !== "string" || value.length === 0 || value.length > MAX_MODEL_ID) return ""
  // A canonical identity is never normalized or truncated. Reject values that
  // would change under display sanitization instead of targeting another model.
  return plainText(value, MAX_MODEL_ID) === value ? value : ""
}

/** Build a display/action model record from one API entry. */
function modelFrom(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)) return null
  var sourceName = typeof value.name === "string" ? value.name : value.model
  var displayName = plainText(sourceName, MAX_TEXT)
  if (!displayName) return null
  // The helper never reconstructs action identity from a display value. Only
  // ollama-ps.rb may provide action_id, preserving the original API identifier.
  var modelId = canonicalModelId(value.action_id)
  return {
    // name remains a compatibility alias for existing panel consumers. It is
    // exact only when actionable; Service.qml verifies modelId before action.
    name: modelId || displayName,
    displayName: displayName,
    modelId: modelId,
    actionable: modelId !== "",
    size: safeNumber(value.size),
    sizeVram: safeNumber(value.size_vram),
    context: safeContext(value.context_length),
    expiresAt: plainText(value.expires_at, 80)
  }
}

/** Parse one server block from the transport's grouped status payload. */
function serverFrom(value) {
  if (!isPlainObject(value)) return null
  var rawModels = Array.isArray(value.models) ? value.models : []
  var models = []
  for (var i = 0; i < rawModels.length; i++) {
    var model = modelFrom(rawModels[i])
    if (model) models.push(model)
  }
  var count = Number(value.loadedModelCount)
  if (!isFinite(count) || count < 0) count = models.length
  count = Math.max(models.length, Math.floor(count))
  return {
    name: plainText(value.name, MAX_TEXT) || "server",
    url: plainText(value.url, MAX_URL),
    version: plainText(value.version, 80),
    state: value.state === "online" ? "online" : "unavailable",
    error: plainText(value.error, MAX_ERROR),
    models: models,
    loadedModelCount: count,
    aggregateVramBytes: safeNumber(value.aggregateVramBytes)
  }
}

/** Parse the multi-server status payload and roll up aggregate widget state. */
function parseServers(result) {
  var invalid = {
    state: "unavailable", servers: [], totalLoadedModelCount: 0,
    totalAggregateVramBytes: 0, anyOnline: false,
    error: "Ollama returned an invalid status response."
  }
  if (!result || typeof result !== "object" || result.ok !== true || !result.data || !Array.isArray(result.data.servers))
    return invalid

  var servers = []
  var total = 0
  var vram = 0
  var anyOnline = false
  var anyModels = false
  for (var i = 0; i < result.data.servers.length; i++) {
    var server = serverFrom(result.data.servers[i])
    if (!server) continue
    servers.push(server)
    total += server.loadedModelCount
    vram += server.aggregateVramBytes
    if (server.state === "online") anyOnline = true
    if (server.models.length > 0) anyModels = true
  }

  var state
  if (servers.length === 0) state = "unavailable"
  else if (!anyOnline) state = "unavailable"
  else if (anyModels) state = "loaded"
  else state = "idle"

  return {
    state: state,
    servers: servers,
    totalLoadedModelCount: total,
    totalAggregateVramBytes: vram,
    anyOnline: anyOnline,
    error: ""
  }
}

/** Parse transport stdout as JSON; validate the operation tag. */
function parseResult(output, operation) {
  try {
    var result = JSON.parse(String(output || ""))
    if (!result || typeof result !== "object" || result.operation !== operation)
      throw new Error("invalid result")
    return result
  } catch (error) {
    return { ok: false, operation: operation, error: "Ollama returned an invalid response.", kind: "invalid_data" }
  }
}

/** Extract the error message from a failed result, or return fallback. */
function errorFor(result, fallback) {
  if (!result || result.ok === true) return ""
  return plainText(result.error, MAX_ERROR) || fallback
}

/** Human-readable byte size (B/KB/MB/GB/TB). */
function formatBytes(value) {
  var amount = safeNumber(value), units = ["B", "KB", "MB", "GB", "TB"], index = 0
  if (amount <= 0) return ""
  while (amount >= 1024 && index < units.length - 1) { amount /= 1024; index++ }
  return amount.toFixed(index > 1 ? 1 : 0) + " " + units[index]
}

/** Relative expiry label ("Unloads in 5m"), or "" if absent/invalid. */
function relativeExpiry(value) {
  var seconds = Math.floor((Date.parse(value) - Date.now()) / 1000)
  if (!isFinite(seconds)) return ""
  if (seconds <= 0) return "Unloads soon"
  if (seconds < 60) return "Unloads in <1m"
  if (seconds < 3600) return "Unloads in " + Math.ceil(seconds / 60) + "m"
  return "Unloads in " + Math.ceil(seconds / 3600) + "h"
}

if (typeof module !== "undefined") {
  module.exports = {
    plainText: plainText,
    boundedInteger: boundedInteger,
    isPlainObject: isPlainObject,
    normalizeServers: normalizeServers,
    stringifyServers: stringifyServers,
    normalizeSettings: normalizeSettings,
    classifyErrorKind: classifyErrorKind,
    safeNumber: safeNumber,
    safeContext: safeContext,
    canonicalModelId: canonicalModelId,
    modelFrom: modelFrom,
    parseServers: parseServers,
    parseResult: parseResult,
    errorFor: errorFor,
    formatBytes: formatBytes,
    relativeExpiry: relativeExpiry
  }
}
