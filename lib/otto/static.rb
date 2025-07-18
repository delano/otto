# lib/otto/static.rb

class Otto
  module Static
    extend self

    def server_error
      [500, { 'Content-Type' => 'text/plain' }, ['Server error']]
    end

    def not_found
      [404, { 'Content-Type' => 'text/plain' }, ['Not Found']]
    end
  end
end
