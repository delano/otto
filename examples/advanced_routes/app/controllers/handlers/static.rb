# examples/advanced_routes/app/controllers/handlers/static.rb

module Handlers
  class Static
    def self.serve
      [200, { 'content-type' => 'text/html' }, ['<h1>Static Handler</h1><p>Static content served</p>']]
    end
  end
end
