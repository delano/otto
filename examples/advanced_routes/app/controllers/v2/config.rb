# frozen_string_literal: true

module V2
  class Config
    def self.update
      [200, { 'content-type' => 'application/json' }, ['{"message": "V2 config updated"}']]
    end
  end
end
