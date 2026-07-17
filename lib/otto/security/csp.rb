# lib/otto/security/csp.rb
#
# frozen_string_literal: true

#
# Index file for Content-Security-Policy components — both halves of Otto's CSP
# support live under Otto::Security::CSP.
#
# EMISSION (delano/otto#180):
# - Policy       — builds the policy string (directive sets, report-uri/report-to).
# - Nonce        — the framework-owned lazy nonce (Otto::Security::CSP.nonce /
#                  Otto::Request#csp_nonce), memoized in env['otto.nonce'].
# - Writer       — the single structural apply core (in-place, key-scoped writes,
#                  Result object, :override / :backstop modes) that every surface
#                  routes through: Otto::Response#apply_csp, the EmitMiddleware,
#                  and the deprecated Otto::Response#send_csp_headers shim.
# - EmitMiddleware — passive backstop that emits a nonce CSP for responses whose
#                  request consumed a nonce (emit-if-consumed). See
#                  Otto::Security::Core#enable_csp_emission!.
#
# RECEPTION (delano/otto#174):
# - Report, Parser, ReportMiddleware — a turnkey violation-report endpoint plus a
#   callback API. See Otto::Security::Core#enable_csp_reporting!.

require_relative 'csp/policy'
require_relative 'csp/nonce'
require_relative 'csp/writer'
require_relative 'csp/report'
require_relative 'csp/parser'
require_relative 'csp/report_middleware'
require_relative 'csp/emit_middleware'
