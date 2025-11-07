# frozen_string_literal: true

module V2
  class Settings
    def self.modify
      [200, { 'content-type' => 'application/json' }, ['{"message": "V2 settings modified", "csrf": "exempt"}']]
    end
  end
end
