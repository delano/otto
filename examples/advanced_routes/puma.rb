#!/usr/bin/env ruby
# frozen_string_literal: true

require 'puma'

# The shared config file returns the configured Otto app
otto_app = require_relative 'config'

# Configure Puma server
Puma::Server.new(otto_app).tap do |server|
  server.add_tcp_listener '127.0.0.1', 9292

  puts "Otto Advanced Routes Example running on http://localhost:9292"
  puts "Press Ctrl+C to stop"

  # Handle Ctrl+C gracefully
  trap('INT') { server.stop }

  server.run
end
