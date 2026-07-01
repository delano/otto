# examples/caddy_tls_demo/standalone.ru
#
# STRONGEST isolation for the Caddy on-demand TLS permission endpoint: run it as
# its own tiny Otto app, bound to a dedicated loopback-only port, physically
# separate from your public-facing application. This is the topology used in
# production (cf. the OneTimeSecret "Internal ACME" app the pilot absorbs).
#
# This is ALSO how you support Caddy and the app running on DIFFERENT hosts: run
# this tiny app on the Caddy host (Caddy -> endpoint stays loopback), and let the
# permission block below reach your real domain data over your own authenticated
# channel (internal API, shared DB, cache). The loopback guard never has to trust
# a cross-host source IP.
#
# Because this process listens only on 127.0.0.1 and serves *nothing else*, the
# endpoint is unreachable from outside the host by construction; the localhost
# guard is then a second layer, not the only one.
#
# Run it on a dedicated loopback port:
#
#   rackup examples/caddy_tls_demo/standalone.ru -o 127.0.0.1 -p 12020
#
# Point Caddy at that port (config-only; `ask` and `permission http` are equivalent):
#
#   on_demand_tls {
#     permission http { endpoint http://127.0.0.1:12020/_caddy/tls-permission }
#   }

require_relative '../../lib/otto'
require_relative 'app'

# No routes file: this app serves ONLY the permission endpoint.
acme = Otto.new

acme.enable_caddy_tls! do |domain|
  DomainDirectory.allowed?(domain)
end

run acme
