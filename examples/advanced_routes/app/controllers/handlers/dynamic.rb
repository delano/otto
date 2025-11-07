# examples/advanced_routes/app/controllers/handlers/dynamic.rb

module Handlers
  class Dynamic
    def process
      [200, { 'content-type' => 'application/json' }, ['{"handler": "dynamic", "processed": true}']]
    end
  end
end
