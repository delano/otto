# frozen_string_literal: true

module Modules
  class Transformer
    def transform
      [200, { 'content-type' => 'application/json' }, ['{"transformation": "complete", "csrf": "exempt"}']]
    end
  end
end
