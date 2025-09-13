# frozen_string_literal: true

module Handlers
  class Dynamic
    def process
      [200, { 'content-type' => 'application/json' }, ['{"handler": "dynamic", "processed": true}']]
    end
  end
end
