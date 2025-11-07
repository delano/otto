# frozen_string_literal: true

module Handlers
  class Async
    def execute
      [200, { 'content-type' => 'application/json' }, ['{"execution": "async", "csrf": "exempt"}']]
    end
  end
end
