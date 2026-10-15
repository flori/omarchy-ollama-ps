#!/bin/sh
# ollama-ps.sh — interpreter probe wrapper for the flori.ollama-ps widget.
#
# Quickshell runs this under Process.clearEnvironment, so neither PATH nor
# HOME is guaranteed. We rebuild a search path from $HOME (deriving it from
# our own location if the env didn't provide one), probe for a Ruby
# interpreter (asdf / rbenv / mise shims first, then distro locations), and
# exec it against ollama-ps.rb which sits next to this file.
#
# When no interpreter resolves we emit a `missing_dependency` status line
# (the QML contract) and exit non-zero so the service surfaces a clean error.

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
script=$script_dir/ollama-ps.rb

# HOME: use the env value, else derive from the plugin location
# (~/.config/omarchy/plugins/flori.ollama-ps).
if [ -z "$HOME" ]; then
  case $script_dir in
    */.config/omarchy/plugins/flori.ollama-ps)
      HOME=${script_dir%%/.config/*}
      ;;
  esac
fi

# Rebuild PATH: shim dirs from $HOME first, then standard system locations.
# Any pre-existing PATH (e.g. interactive runs) is appended, not replaced.
probe=$HOME/.asdf/shims:$HOME/.rbenv/shims:$HOME/.local/share/mise/shims:$HOME/bin:$HOME/go/bin:$HOME/.rbenv/bin:$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin
[ -n "${PATH:-}" ] && probe=$probe:${PATH}
export PATH=$probe

# A `ruby` visible on the probe path (shims rank ahead of the distro).
if cmd=$(command -v ruby 2>/dev/null) && [ -n "$cmd" ]; then
  if ! gem which ollama-ruby >/dev/null 2>&1; then
    gem install --silent ollama-ruby
  fi
  exec "$cmd" "$script" "$@"
fi

# No interpreter found: report via the QML contract and fail.
echo '{"ok":false,"operation":"status","kind":"missing_dependency","error":"Missing dependency: ruby is required to run Ollama PS."}'
exit 1
