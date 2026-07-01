# lib/otto/security/csp/report_middleware.rb
#
# frozen_string_literal: true

require_relative 'parser'

class Otto
  module Security
    module CSP
      # Rack middleware that receives browser-posted Content-Security-Policy
      # violation reports and dispatches them to an application callback.
      #
      # This is the receiving half of Otto's CSP support; the emitting half is
      # {Otto::Security::Config#generate_nonce_csp} / {Otto::Response#send_csp_headers}
      # (and the static {Otto::Security::Config#enable_csp!}). When a report URI
      # is configured, the emitted policy carries a `report-uri` directive
      # pointing here.
      #
      # Behavior (all mandatory for a public, unauthenticated receiver):
      #
      # - INERT unless {Otto::Security::Config#csp_report_uri} is set. When it is
      #   not configured the middleware is a transparent pass-through.
      # - Only intercepts a POST whose path matches the configured report URI.
      #   Everything else (other paths, other methods) passes through untouched.
      # - Short-circuits BEFORE inner middleware, so CSRF, auth, and rate
      #   limiting never see the request. This is why browsers can POST reports
      #   with no CSRF token: the report never reaches the CSRF middleware.
      #   {Otto::Security::Core#enable_csp_reporting!} pins this middleware
      #   OUTERMOST (via the :outermost stack position), so the guarantee holds
      #   regardless of the order security features are enabled in. The flip side
      #   is that reports also bypass rate limiting — see the DoS note on
      #   {Otto::Security::Core#enable_csp_reporting!}; keep callbacks cheap.
      # - Enforces a hard {MAX_BODY_BYTES} body cap. Oversized bodies are
      #   detected with a `cap + 1` read and skipped WITHOUT parsing, so a
      #   hostile client cannot force large allocations against a public endpoint.
      # - Parses both wire formats via {Otto::Security::CSP::Parser} and invokes
      #   the registered callback once per normalized report.
      # - NEVER raises to the client and always responds `204 No Content`
      #   (browsers ignore the body). A throwing callback is isolated by
      #   {Otto::Security::Config#dispatch_csp_violation}.
      class ReportMiddleware
        # Hard cap on the request body we are willing to read/parse. Browsers
        # send small JSON documents; anything larger is abuse and is dropped.
        MAX_BODY_BYTES = 64 * 1024 # 64 KiB

        def initialize(app, config = nil)
          @app    = app
          @config = config || Otto::Security::Config.new
        end

        def call(env)
          return @app.call(env) unless report_request?(env)

          receive_report(env)
        end

        private

        # Handle a report POST and always answer 204. A report receiver must
        # never surface an error to the browser, so parse/dispatch failures are
        # contained HERE — deliberately NOT around the #call pass-through, which
        # would swallow unrelated downstream errors (turning every failing
        # request into a silent 204, since this middleware runs outermost).
        def receive_report(env)
          handle_report(env)
          # A fresh header hash + body per call (never a shared/frozen literal)
          # so a downstream server that mutates the response tuple is safe.
          [204, {}, []]
        rescue StandardError => e
          Otto.logger.error("[Otto::CSP] report handling failed: #{e.class}: #{e.message}")
          [204, {}, []]
        end

        # True only when reporting is configured AND this is a POST to the
        # configured report path.
        #
        # @param env [Hash]
        # @return [Boolean]
        def report_request?(env)
          report_uri = @config.csp_report_uri
          return false if report_uri.nil? || report_uri.empty?
          return false unless env['REQUEST_METHOD'] == 'POST'

          env['PATH_INFO'] == report_uri
        end

        # Read (capped), parse, and dispatch. Never raises; parse/dispatch
        # failures are contained so the caller can still return 204.
        #
        # @param env [Hash]
        # @return [void]
        def handle_report(env)
          body = read_capped_body(env)
          return if body.nil?

          reports = Otto::Security::CSP::Parser.parse(body, env['CONTENT_TYPE'])
          reports.each { |report| @config.dispatch_csp_violation(report) }
        end

        # Read at most MAX_BODY_BYTES + 1 bytes so an oversized body is detected
        # without ever materializing more than the cap. Returns nil when there is
        # no readable body or the body exceeds the cap (skip without parsing).
        #
        # @param env [Hash]
        # @return [String, nil]
        def read_capped_body(env)
          input = env['rack.input']
          return nil if input.nil?

          chunk = input.read(MAX_BODY_BYTES + 1)
          input.rewind if input.respond_to?(:rewind)
          return nil if chunk.nil? || chunk.empty?
          return nil if chunk.bytesize > MAX_BODY_BYTES # oversized: drop unparsed

          chunk
        end
      end
    end
  end
end
