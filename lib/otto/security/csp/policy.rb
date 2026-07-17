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
        # @param directive_overrides [Hash, nil] per-directive overrides merged
        #   into the base set before reporting directives are appended. See
        #   {.merge_directives} for the accepted shape (replace a directive's
        #   sources, add a new directive, or remove one with a nil/false value).
        # @return [String] complete CSP policy string
        def nonce_policy(nonce, development_mode: false, report_uri: nil, report_to_url: nil, directive_overrides: nil)
          directives = development_mode ? development_directives(nonce) : production_directives(nonce)
          directives = merge_directives(directives, directive_overrides)
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

        # Merge per-directive overrides into a base directive set.
        #
        # This is the customization seam the hardcoded directive sets previously
        # lacked: a consuming app can adjust ANY directive (e.g. re-allow
        # `data:` workers via `worker-src 'self' data: blob:`) without
        # vendoring the gem. Order is
        # preserved — an override that matches an existing directive replaces it
        # in place; an override for a directive not in the base set is appended
        # after the base directives (before any reporting directives).
        #
        # Override values:
        # - a String  → the directive's source list verbatim, e.g.
        #   `'worker-src' => "'self' blob:"` yields `worker-src 'self' blob:;`
        # - an Array   → sources joined with a single space, e.g.
        #   `%w['self' blob:]`
        # - `nil`/`false` → REMOVE the directive from the emitted policy
        #
        # Directive names are matched case-insensitively (CSP directive names are
        # case-insensitive) and may be given as Strings or Symbols.
        #
        # @note The per-request nonce is embedded in `script-src` (production)
        #   and cannot be reproduced in a static override, so replacing (or
        #   removing) `script-src` strips the nonce from the emitted header and
        #   DEFEATS nonce protection: the browser then accepts any inline script
        #   the page carries the nonce attribute on. Overriding `script-src`
        #   while nonce mode is enabled therefore disables nonce enforcement;
        #   {Otto::Security::Config} logs a warning when such an override is
        #   configured. Override other directives freely.
        #
        # @param directives [Array<String>] base directive strings, each `;`-terminated
        # @param overrides [Hash, nil] directive name => source list / nil
        # @return [Array<String>] merged directive strings, each `;`-terminated
        # @raise [ArgumentError] if an override name or source token contains a
        #   `;`, newline, or carriage return (see {.build_directive})
        def merge_directives(directives, overrides)
          return directives if overrides.nil? || overrides.empty?

          normalized = normalize_overrides(overrides)
          consumed   = {}

          merged = directives.filter_map do |directive|
            name = directive_name(directive)
            next directive unless normalized.key?(name)

            consumed[name] = true
            build_directive(name, normalized[name])
          end

          normalized.each do |name, value|
            next if consumed[name]

            appended = build_directive(name, value)
            merged << appended if appended
          end

          merged
        end

        # Normalize an overrides hash to lowercased, hyphenated String keys so
        # lookups are case-insensitive and Symbol/String keys are
        # interchangeable. Underscores map to hyphens (no CSP directive contains
        # an underscore) so a Symbol key like `:worker_src` addresses the
        # `worker-src` directive. Blank keys are dropped.
        #
        # @param overrides [Hash]
        # @return [Hash{String=>Object}]
        def normalize_overrides(overrides)
          overrides.each_with_object({}) do |(key, value), acc|
            name = key.to_s.strip.downcase.tr('_', '-')
            acc[name] = value unless name.empty?
          end
        end

        # The directive name (first token) of a `;`-terminated directive string,
        # lowercased for case-insensitive matching.
        #
        # @param directive [String]
        # @return [String]
        def directive_name(directive)
          directive.to_s.strip.delete_suffix(';').split(/\s+/, 2).first.to_s.downcase
        end

        # Build a single `;`-terminated directive string from a name and an
        # override value, or nil when the value signals removal (nil/false).
        #
        # The directive name and each source token are validated against CSP's
        # separator characters: a name or token containing `;` (which separates
        # directives), a newline, or a carriage return raises {ArgumentError}
        # rather than silently injecting extra directives — a real footgun when
        # overrides come from env/config files. (The `false` removal sentinel is
        # checked before {Array} so a bare `false` never becomes a `[false]`
        # source list.)
        #
        # @param name [String] directive name
        # @param value [String, Array, nil, false] source list, or nil/false to remove
        # @return [String, nil]
        # @raise [ArgumentError] if the name or a source token contains a `;`,
        #   newline, or carriage return
        def build_directive(name, value)
          return nil if value.nil? || value == false

          reject_injection!('directive name', name)
          sources = Array(value).filter_map do |token|
            str = token.to_s.strip
            next if str.empty?

            reject_injection!("source for #{name}", str)
            str
          end.join(' ')
          sources.empty? ? "#{name};" : "#{name} #{sources};"
        end

        # Raise {ArgumentError} when +text+ carries a CSP directive/token
        # separator (`;`, newline, or carriage return) that would let an
        # override break out of its directive and inject another.
        #
        # @param label [String] what is being validated (for the error message)
        # @param text [String]
        # @return [void]
        # @raise [ArgumentError] if +text+ contains `;`, `\n`, or `\r`
        def reject_injection!(label, text)
          return unless text.match?(/[;\r\n]/)

          raise ArgumentError,
                "invalid CSP #{label}: #{text.inspect} contains a ';', newline, or carriage return"
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
            "worker-src 'self' blob:;",
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
            "worker-src 'self' blob:;",                # Allow Workers from same origin and blob: URLs
          ]
        end
      end
    end
  end
end
