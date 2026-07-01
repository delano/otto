# examples/caddy_tls_demo/config.ru

require_relative '../../lib/otto'
require_relative 'app'

# Resolve the routes file relative to this file, not the process CWD, so the
# documented `rackup examples/caddy_tls_demo/config.ru` works from the repo root.
app = Otto.new(File.expand_path('routes', __dir__))

# Enable the Caddy on-demand TLS permission endpoint. The block is the only
# application-specific part: it receives the domain Caddy is asking about and
# returns truthy to allow a certificate (HTTP 200) or falsy to deny (HTTP 403).
# Any exception raised inside the block is caught and treated as a denial
# (fail-closed). Requests from non-loopback peers are rejected with 401 by
# default (localhost_only: true).
app.enable_caddy_tls! do |domain|
  DomainDirectory.allowed?(domain)
end

# The endpoint is now served at:  GET /_caddy/tls-permission?domain=<host>
#
# Point Caddy at it (config-only; the deprecated `ask` and the new
# `permission http` directives speak the identical HTTP contract):
#
#   on_demand_tls {
#     permission http { endpoint http://127.0.0.1:9292/_caddy/tls-permission }
#   }
#   # legacy / deprecated, same endpoint:
#   on_demand_tls { ask http://127.0.0.1:9292/_caddy/tls-permission }

run app
