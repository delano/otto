module Modules
  class DataValidator
    def validate
      [200, { 'content-type' => 'application/json' }, ['{"message": "Data validation completed"}']]
    end
  end
end
