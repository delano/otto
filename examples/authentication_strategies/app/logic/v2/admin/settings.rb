module V2
  module Admin
    class Settings
      def self.update
        [200, { 'content-type' => 'application/json' }, ['{"message": "V2 Admin settings updated"}']]
      end
    end
  end
end
