# examples/lambda_handlers/handlers.rb
#
# frozen_string_literal: true

# Pre-registered lambda route handlers (Otto issue #41).
#
# A lambda handler is any object responding to #call that accepts exactly
# three arguments: (req, res, extra_params).
#
#   * req          - the Rack::Request for this request
#   * res          - the Rack::Response to populate
#   * extra_params - a Hash of route/path params merged by Otto
#
# These procs are handed to Otto at construction time via the
# `lambda_handlers:` option (see config.ru). Each is looked up O(1) by name
# from the route file's `&handler_name` syntax. Nothing in the route file is
# ever eval'd — only names present in this registry can be invoked, and an
# unknown name fails loudly instead of executing arbitrary code.
#
# How the response is produced depends on the route's `response=` option,
# exactly like the class/instance/logic handler kinds:
#
#   * default (no `response=`) -> the handler mutates `res` directly
#     (status/headers/body); the return value is ignored.
#   * `response=json`          -> the returned Hash is serialized to JSON.
module LambdaHandlers
  # A minimal string responder. With no `response=` option the default response
  # handler leaves the body alone, so (like a class handler) we write it here.
  HEALTH_CHECK = lambda do |_req, res, _extra|
    res.headers['content-type'] = 'text/plain; charset=utf-8'
    res.body = 'OK'
  end

  # A Hash responder. Pair it with `response=json` on the route and Otto's
  # JSON response handler serializes the Hash and sets the JSON content-type.
  STATUS = lambda do |_req, _res, _extra|
    {
      service: 'otto-lambda-demo',
      status: 'healthy',
      time: Time.now.utc.iso8601,
    }
  end

  # A handler that reads merged params. Path/query params arrive in
  # `extra_params`; request params are available through `req`.
  GREET = lambda do |req, _res, extra|
    name = extra['name'] || req.params['name'] || 'world'
    { greeting: "Hello, #{name}!" }
  end

  # A webhook-style POST handler. The matching route declares `csrf=exempt`
  # so external callers (which cannot present a CSRF token) are not rejected.
  # Security note: exempt CSRF only for endpoints authenticated another way
  # (signature header, shared secret, etc.).
  WEBHOOK = lambda do |req, _res, _extra|
    # Rewind first: upstream middleware may already have read the input stream.
    req.body.rewind if req.body.respond_to?(:rewind)
    payload = req.body.read.to_s
    # NOTE: this route uses `response=json`, so Otto's JSON response handler
    # owns the status (200) and content-type. Setting them here would be
    # overridden, so we only return the Hash to be serialized.
    { received: true, bytes: payload.bytesize }
  end

  # The registry passed to Otto.new(lambda_handlers: ...). Keys are the names
  # referenced after '&' in the routes file.
  REGISTRY = {
    'health_check' => HEALTH_CHECK,
    'status'       => STATUS,
    'greet'        => GREET,
    'webhook'      => WEBHOOK,
  }.freeze
end
