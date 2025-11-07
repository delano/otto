# examples/advanced_routes/app/controllers/modules/validator.rb

module Modules
  class Validator
    def validate
      [200, { 'content-type' => 'application/json' }, ['{"validation": "passed", "module": "Validator"}']]
    end
  end
end
