# examples/advanced_routes/app/controllers/handlers/async.rb

module Handlers
  class Async
    def execute
      [200, { 'content-type' => 'application/json' }, ['{"execution": "async", "csrf": "exempt"}']]
    end
  end
end
