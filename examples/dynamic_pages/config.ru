# examples/basic/config.ru

# OTTO EXAMPLE APP CONFIG - 2025-08-18
#
# Usage:
#
#     $ thin -e dev -R config.ru -p 10770 start

public_path = File.expand_path('../../public', __dir__)

require_relative '../../lib/otto'
require_relative 'app'

app = Otto.new("routes")

# DEV: Run web apps with extra logging and reloading
if Otto.env?(:dev)

  map('/') do
    use Rack::CommonLogger
    use Rack::Reloader, 0
    app.option[:public] = public_path
    app.add_static_path '/favicon.ico'
    run app
  end

# PROD: run the webapp on the metal
else
  map('/') { run app }
end
