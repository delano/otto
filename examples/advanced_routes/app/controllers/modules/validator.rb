# frozen_string_literal: true

module Modules
  class Validator
    def validate
      [200, { 'content-type' => 'application/json' }, ['{"validation": "passed", "module": "Validator"}']]
    end
  end
end
