# lib/otto/security/csp/policy.rb
#
# frozen_string_literal: true

class Otto
  module Security
    module CSP
      # Assembles Content-Security-Policy strings from Otto's directive sets and
      # the optional reporting directives.
      #
      # This is the policy-BUILDING half of Otto's CSP support, extracted from
      # {Otto::Security::Config} so the domain (directive sets, report-uri /
      # report-to assembly) lives beside the parser and the middlewares under
      # {Otto::Security::CSP}. {Otto::Security::Config} keeps thin delegating
      # facades ({Otto::Security::Config#generate_nonce_csp} and its static
      # counterpart), so callers and output are unchanged — the assembly logic
      # simply has a home of its own now.
      #
      # All methods are pure functions of their arguments (the report URI/URL are
      # passed in, not read from global state), so the same policy string can be
      # produced from any surface without a Config in hand.
      module Policy
        module_function

        # Endpoint group name shared by the CSP `report-to` directive and the
        # `Reporting-Endpoints` response header (modern Reporting API). Browsers
        # match the directive's group to the header's key, so both must agree.
        # {Otto::Security::Config::CSP_REPORTING_GROUP} aliases this so the two
        # can never drift.
        REPORTING_GROUP = 'otto-csp'

        # Build the per-request nonce CSP policy string.
        #
        # Byte-identical to Otto's historical {Otto::Security::Config#generate_nonce_csp}
        # output: the base directive set (development or production) followed by
        # the optional `report-uri` and `report-to` directives, each terminated
        # with `;` and joined by a single space.
        #
        # @param nonce [String] nonce value injected into `script-src`
        # @param development_mode [Boolean] use the development directive set
        # @param report_uri [String, nil] path for the `report-uri` directive
        #   (omitted when nil/empty)
        # @param report_to_url [String, nil] absolute URL configured for the
        #   modern Reporting API; its presence (not its value) toggles the
        #   `report-to <group>` directive (omitted when nil/empty)
        # @return [String] complete CSP policy string
        def nonce_policy(nonce, development_mode: false, report_uri: nil, report_to_url: nil)
          directives = development_mode ? development_directives(nonce) : production_directives(nonce)
          uri_directive = report_uri_directive(report_uri)
          to_directive  = report_to_directive(report_to_url)
          directives += ["#{uri_directive};"] if uri_directive
          directives += ["#{to_directive};"] if to_directive
          directives.join(' ')
        end

        # Build a static CSP header value: a base policy plus the optional
        # reporting directives, joined `'; '`. Byte-identical to the bare policy
        # when no reporting is configured.
        #
        # @param base [String] the base policy (e.g. from {Otto::Security::Config#enable_csp!})
        # @param report_uri [String, nil] path for the `report-uri` directive
        # @param report_to_url [String, nil] absolute URL toggling `report-to`
        # @return [String]
        def static_policy(base, report_uri: nil, report_to_url: nil)
          [base, report_uri_directive(report_uri), report_to_directive(report_to_url)].compact.join('; ')
        end

        # The `report-uri` directive, or nil when no report URI is configured.
        # No trailing semicolon (callers add their own separator).
        #
        # @param uri [String, nil]
        # @return [String, nil]
        def report_uri_directive(uri)
          return nil if uri.nil? || uri.empty?

          "report-uri #{uri}"
        end

        # The `report-to` directive (modern Reporting API), or nil when no
        # reporting endpoint URL is configured. Its group name matches the
        # Reporting-Endpoints header. No trailing semicolon.
        #
        # @param url [String, nil]
        # @return [String, nil]
        def report_to_directive(url)
          return nil if url.nil? || url.empty?

          "report-to #{REPORTING_GROUP}"
        end

        # CSP directives for the development environment.
        #
        # Development mode allows inline scripts/styles and hot reloading
        # connections for better developer experience with build tools like Vite.
        #
        # @param nonce [String] nonce value injected into `script-src`
        # @return [Array<String>] directive strings, each terminated with `;`
        def development_directives(nonce)
          [
            "default-src 'none';",
            "script-src 'nonce-#{nonce}' 'unsafe-inline';", # Allow inline scripts for development tools
            "style-src 'self' 'unsafe-inline';",
            "connect-src 'self' ws: wss: http: https:;", # Allow HTTP and all WebSocket connections for dev tools
            "img-src 'self' data:;",
            "font-src 'self';",
            "object-src 'none';",
            "base-uri 'self';",
            "form-action 'self';",
            "frame-ancestors 'none';",
            "manifest-src 'self';",
            "worker-src 'self' data:;",
          ]
        end

        # CSP directives for the production environment.
        #
        # Production mode is more restrictive, only allowing HTTPS connections
        # and nonce-only scripts for enhanced XSS protection.
        #
        # @param nonce [String] nonce value injected into `script-src`
        # @return [Array<String>] directive strings, each terminated with `;`
        def production_directives(nonce)
          [
            "default-src 'none';",                     # Restrict to same origin by default
            "script-src 'nonce-#{nonce}';",            # Only allow scripts with valid nonce
            "style-src 'self' 'unsafe-inline';",       # Allow inline styles and same-origin stylesheets
            "connect-src 'self' wss: https:;",         # Only HTTPS and secure WebSockets
            "img-src 'self' data:;",                   # Allow images from same origin and data URIs
            "font-src 'self';",                        # Allow fonts from same origin only
            "object-src 'none';",                      # Block <object>, <embed>, and <applet> elements
            "base-uri 'self';",                        # Restrict <base> tag targets to same origin
            "form-action 'self';",                     # Restrict form submissions to same origin
            "frame-ancestors 'none';",                 # Prevent site from being embedded in frames
            "manifest-src 'self';",                    # Allow web app manifests from same origin
            "worker-src 'self' data:;",                # Allow Workers from same origin and data blobs
          ]
        end
      end
    end
  end
end
