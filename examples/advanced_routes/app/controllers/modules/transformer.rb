# examples/advanced_routes/app/controllers/modules/transformer.rb

module Modules
  class Transformer
    def transform
      [200, { 'content-type' => 'application/json' }, ['{"transformation": "complete", "csrf": "exempt"}']]
    end
  end
end
