# examples/advanced_routes/app/controllers/modules/auth.rb

module Modules
  class Auth
    def process
      [200, { 'content-type' => 'text/html' }, ['<h1>Auth Module</h1><p>Instance method implementation</p>']]
    end
  end
end
