#!/usr/bin/env ruby
# Ollama transport for the flori.ollama-ps bar widget.
#
# Multi-server: fans out GET /api/ps (and per-server version) across every
# Ollama host configured on the widget, reporting each server independently
# so one dead box can never hide a live one.
#
# Usage:  ollama-ps.rb <status | unload [model] [server-url]>
# Env:    OLLAMA_SERVERS       JSON object { "name": "http://host:port", ... }
#         OLLAMA_URL           single-host fallback (name derived from hostname)
#         OLLAMA_PS_MAX_MODELS Maximum number of model details reported
# Output: a single JSON line on stdout matching the QML service contract.

require 'json'
require 'ollama'
require 'uri'
require 'thread'
require 'time'

# Maximum number of model details reported to keep the QML payload bounded,
# counts and vram aggregates are honest, though.
MAX_MODELS = ENV.fetch('OLLAMA_PS_MAX_MODELS', 12).to_i.nonzero? || 12

# Resolves the Ollama server base URL for the Ruby client.
#
# Prioritizes the OLLAMA_URL environment variable if it is explicitly
# defined. Otherwise, it constructs a URL from the OLLAMA_HOST environment
# variable, defaulting to localhost:11434 if that variable is also unset.
#
# @return [ URI ] The resolved base URL for the Ollama API endpoint
def default_base_url
  if ENV['OLLAMA_URL'].to_s.strip.empty? && ENV['OLLAMA_HOST'].to_s.strip.empty?
    URI.parse('http://localhost:11434')
  else
    URI.parse(ENV['OLLAMA_URL'] || 'http://%s' % ENV.fetch('OLLAMA_HOST', 'localhost:11434'))
  end
end

# Resolves the configured Ollama server connections for the plugin.
#
# Checks the OLLAMA_SERVERS environment variable for a JSON hash mapping
# server names to URLs. If valid and non-empty, returns those entries in
# configuration order. Otherwise, or upon any parsing error, falls back to
# a single host derived from OLLAMA_URL / OLLAMA_HOST.
#
# @return [ Array<Hash{Symbol => String}> ] A list of server definitions,
#   where each entry is a hash with :name (String) and :url (String) keys.
def load_servers
  servers = ENV['OLLAMA_SERVERS']
  if servers && !servers.strip.empty?
    data = JSON.parse(servers)
    return data.map { |n, u| { name: n.to_s, url: u.to_s } } if data.is_a?(Hash) && !data.empty?
  end
  raise 'fallback'
rescue
  url = default_base_url
  [{ name: url.hostname.sub(%r{\..*}, ''), url: url.to_s }]
end

# Serializes a structured error response for the shared third-party service.
# Builds a hash with a false ok status, the operation context, the error kind,
# and the underlying error message, then returns it as a JSON string.
#
# @param operation [ String ] the name of the operation that failed (e.g., "status", "unload")
# @param kind [ String ] the category or classification of the error
# @param error [ String ] the specific error message
#
# @return [ String ] a JSON string representing the error state
def err(operation, kind, error)
  JSON.dump(ok: false, operation:, kind:, error:)
end

# Coerces the given value into a non-negative, finite floating-point number.
#
# Attempts to parse the input as a Float. If the conversion succeeds and the
# result is zero or greater and finite, that value is returned. If the
# conversion fails, the value is negative, or the value is infinite, zero is
# returned.
#
# @param v [ Object ] The value to be converted. Typically a String or Numeric.
#
# @return [ Float ] The resulting non-negative finite number, or 0 if invalid
def safe_num(v)
  n = Float(v)
  n >= 0 && n.finite? ? n : 0.to_f
rescue
  0.0
end

# Queries the Ollama server for its version and list of loaded models to
# construct the widget state payload.
#
# The method extracts the server version (truncated to 80 characters) and
# iterates over the reported models to aggregate VRAM usage and prepare a
# capped list of model entries for display. Each model entry includes the
# name (truncated to 512 characters), an optional action_id (full name when
# ≤ 256 chars), size, VRAM size, context length, and expiration time.
# Models without a name are skipped.
#
# In the event of a timeout, socket error, Ollama API error, or any other
# exception, the method returns a payload indicating the server is unavailable,
# along with a specific error kind and message.
#
# @param entry [ Hash ] the configuration entry for the bar widget, containing
#                       the :name and :url keys.
#
# @return [ Hash ] a hash containing the widget state (online or unavailable),
#                  server version, list of models, loaded model count,
#                  aggregate VRAM bytes, and error details if unavailable.
def build_server(entry)
  name   = entry[:name]
  url    = entry[:url]
  client = Ollama::Client.new(base_url: url, connect_timeout: 3, read_timeout: 3)

  version = client.version[:version].to_s[0, 80]

  client_models = Array(client.ps.models)

  models = []
  vram   = 0.0
  client_models.each do |m|
    nm = m.model
    next if nm.empty?
    sv = safe_num(m.size_vram)
    vram += sv
    h = { name: nm[0, 512] }
    h[:action_id]      = nm if nm.length <= 256
    h[:size]           = safe_num(m.size)
    h[:size_vram]      = sv
    h[:context_length] = safe_num(m.context_length)
    exp = m.expires_at
    h[:expires_at] = exp[0, 512] if exp.is_a?(String)
    models << h
  end

  { name:, url:, state: 'online', version:, models:,
    loadedModelCount: models.length, aggregateVramBytes: vram
  }
rescue Ollama::Errors::TimeoutError
  { name:, url:, state: 'unavailable', version: '',
    error: 'The request timed out.', kind: 'operation_timeout',
    models: [], loadedModelCount: 0, aggregateVramBytes: 0.0 }
rescue Ollama::Errors::SocketError
  { name:, url:, state: 'unavailable', version: '',
    error: 'Cannot reach the server.', kind: 'transport_error',
    models: [], loadedModelCount: 0, aggregateVramBytes: 0.0 }
rescue Ollama::Errors::Error => e
  { name:, url:, state: 'unavailable', version: '',
    error: e.message[0, 200], kind: 'api_error',
    models: [], loadedModelCount: 0, aggregateVramBytes: 0.0 }
rescue => e
  { name:, url:, state: 'unavailable', version: '',
    error: "#{e.class}: #{e.message[0, 200]}", kind: 'internal_error',
    models: [], loadedModelCount: 0, aggregateVramBytes: 0.0 }
end

operation = ARGV[0] || 'status'

case operation
when 'status'
  tg = ThreadGroup.new
  load_servers.each { |e| tg.add Thread.new { build_server(e) } }
  servers = tg.list.map(&:join).map(&:value)
  keep = {}
  servers.each_with_index do |s, i|
    s[:models].each do |m|
      expires_at = Time.parse(m[:expires_at]).to_f rescue nil
      keep[ [ i, m[:name] ] ] = expires_at || Float::INFINITY
    end
  end
  keep = keep.sort_by(&:last).reverse.first(MAX_MODELS)
  servers.each_with_index do |s, i|
    s[:models].select! { |m| keep.assoc([ i, m[:name] ]) }
  end
  puts JSON.dump(ok: true, operation: 'status', data: { servers: })

when 'unload'
  model = ARGV[1].to_s
  url   = ARGV[2].to_s
  if model.empty? || model.length > 256 || model != model.strip
    puts err('unload', 'invalid_request',
             'No valid model was selected to unload.')
  elsif url.empty?
    puts err('unload', 'invalid_request',
             'No server was selected for the unload.')
  else
    begin
      client = Ollama::Client.new(base_url: url)
      client.chat(model:, messages: [], keep_alive: 0)
      puts JSON.dump(ok: true, operation: 'unload', data: { done: true })
    rescue Ollama::Errors::TimeoutError
      puts err('unload', 'operation_timeout', 'The request timed out.')
    rescue Ollama::Errors::SocketError
      puts err('unload', 'transport_error', 'Cannot reach the server.')
    rescue Ollama::Errors::Error => e
      puts err('unload', 'api_error', e.message[0, 200])
    rescue => e
      puts err('unload', 'internal_error', "#{e.class}: #{e.message[0, 200]}")
    end
  end

else
  puts err('status', 'invalid_request', 'Unknown Ollama operation.')
end
