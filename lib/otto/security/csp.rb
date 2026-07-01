# lib/otto/security/csp.rb
#
# frozen_string_literal: true

#
# Index file for Content-Security-Policy violation reporting components.
#
# Otto emits CSP headers via Otto::Security::Config (static #enable_csp! and
# nonce-based #generate_nonce_csp / Otto::Response#send_csp_headers). This
# module adds the receiving half: a turnkey violation-report endpoint plus a
# callback API, so an application can collect CSP reports with a few lines of
# config instead of hand-rolling a parser, size cap, and CSRF exemption.
#
# See Otto::Security::Core#enable_csp_reporting! for the primary entry point and
# delano/otto#174 for the design.

require_relative 'csp/report'
require_relative 'csp/parser'
require_relative 'csp/report_middleware'
