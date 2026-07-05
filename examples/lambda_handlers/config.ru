# examples/lambda_handlers/config.ru
#
# Usage:
#
#     $ rackup config.ru -p 10780
#
# then, in another terminal:
#
#     $ curl localhost:10780/ping
#     $ curl localhost:10780/status
#     $ curl localhost:10780/greet/otto
#     $ curl -X POST --data 'hello' localhost:10780/webhook

require_relative '../../lib/otto'
require_relative 'handlers'

# Register the lambda handlers at construction time. Only names present in
# this Hash can be referenced from the routes file's '&' syntax. Otto
# validates every entry here (must respond to #call, arity of 3) and freezes
# the registry — a route naming an unknown handler fails loudly rather than
# executing anything.
app = Otto.new('routes', {
  lambda_handlers: LambdaHandlers::REGISTRY,
})

run app
