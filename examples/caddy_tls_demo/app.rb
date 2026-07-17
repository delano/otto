# examples/caddy_tls_demo/app.rb
#
# frozen_string_literal: true

# DemoApp serves the example's own pages. It has nothing to do with the Caddy
# permission endpoint — it is here to show that the endpoint (and its localhost
# guard) coexist with a normal Otto application without affecting its routes.
class DemoApp
  def self.index(_req, res)
    res.headers['content-type'] = 'text/html; charset=utf-8'
    res.body = <<~HTML
      <h1>Otto — Caddy on-demand TLS demo</h1>
      <p>This app exposes a Caddy on-demand TLS permission endpoint at
         <code>GET /_caddy/tls-permission?domain=&lt;host&gt;</code>.</p>
      <p>It answers <code>200 OK</code> for allowed domains and <code>403</code>
         otherwise, and only accepts requests from the loopback interface. See
         <code>README.md</code> for <code>curl</code> commands and the Caddyfile.</p>
    HTML
  end

  def self.health(_req, res)
    res.headers['content-type'] = 'text/plain'
    res.body = 'OK'
  end
end

# DomainDirectory stands in for whatever an application uses to decide which
# domains may receive a certificate (a database of verified custom domains, an
# allowlist, an API call, ...). Otto does not care how the decision is made — it
# only calls the block you pass to `enable_caddy_tls!`.
module DomainDirectory
  # In a real app this would check DNS ownership / verification status.
  VERIFIED = %w[
    verified.example.com
    tenant-a.example.com
  ].freeze

  def self.allowed?(domain)
    VERIFIED.include?(domain)
  end
end
