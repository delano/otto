# frozen_string_literal: true

module V2
  class Admin
    def self.show
      [200, { 'content-type' => 'text/html' }, ['<h1>V2 Admin</h1><p>Class method implementation</p>']]
    end
  end
end
