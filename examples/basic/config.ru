# examples/basic/config.ru

# OTTO EXAMPLE APP CONFIG - 2011-12-17
#
# Usage:
#
#     $ thin -e dev -R config.ru -p 10770 start

ENV['RACK_ENV'] ||= 'prod'
ENV['APP_ROOT'] = File.expand_path(File.join(File.dirname(__FILE__)))
$:.unshift(File.join(ENV.fetch('APP_ROOT', nil)))
$:.unshift(File.join(ENV.fetch('APP_ROOT', nil), '..', 'lib'))

require 'otto'
require 'app'

PUBLIC_DIR = "#{ENV.fetch('APP_ROOT', nil)}/public"
APP_DIR = "#{ENV.fetch('APP_ROOT', nil)}"

app = Otto.new("#{APP_DIR}/routes")

if Otto.env?(:dev) # DEV: Run web apps with extra logging and reloading
  map('/') do
    use Rack::CommonLogger
    use Rack::Reloader, 0
    app.option[:public] = PUBLIC_DIR
    app.add_static_path '/favicon.ico'
    run app
  end
  # Specify static paths to serve in dev-mode only
  map('/etc/') { run Rack::Files.new("#{PUBLIC_DIR}/etc") }
  map('/img/') { run Rack::Files.new("#{PUBLIC_DIR}/img") }

else # PROD: run barebones webapp
  map('/') { run app }
end
