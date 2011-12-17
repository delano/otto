# OTTO EXAMPLE APP CONFIG - 2011-12-17
#
# Usage:
# 
#     $ thin -e dev -R config.ru -p 10770 start
#     $ tail -f /var/log/system.log

ENV['RACK_ENV'] ||= 'prod'
ENV['APP_ROOT'] = ::File.expand_path(::File.join(::File.dirname(__FILE__)))
$:.unshift(::File.join(ENV['APP_ROOT']))
$:.unshift(::File.join(ENV['APP_ROOT'], '..', 'lib'))

require 'otto'
require 'app'

PUBLIC_DIR = "#{ENV['APP_ROOT']}/public"
APP_DIR = "#{ENV['APP_ROOT']}"

app = Otto.new("#{APP_DIR}/routes")

if Otto.env?(:dev)      # DEV: Run web apps with extra logging and reloading
  map('/') { 
    use Rack::CommonLogger
    use Rack::Reloader, 0
    app.option[:public] = PUBLIC_DIR
    app.add_static_path '/favicon.ico'
    run app
  }
  # Specify static paths to serve in dev-mode only
  map('/etc/') { run Rack::File.new("#{PUBLIC_DIR}/etc") }
  map('/img/') { run Rack::File.new("#{PUBLIC_DIR}/img") }

else                     # PROD: run barebones webapp
  map('/') { run app }
end
