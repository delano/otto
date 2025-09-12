module Modules
  class AuthHandler
    def process
      [200, { 'content-type' => 'text/html' }, ['<h1>Auth Handler</h1><p>Instance method implementation</p>']]
    end
  end
end
