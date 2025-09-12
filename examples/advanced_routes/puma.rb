#!/usr/bin/env ruby
# frozen_string_literal: true

require 'puma'
require_relative 'config'

# Configure Puma server
Puma::Server.new(otto).tap do |server|
  server.add_tcp_listener '127.0.0.1', 9292

  puts "Otto Advanced Routes Example running on http://localhost:9292"
  puts "Press Ctrl+C to stop"

  # Handle Ctrl+C gracefully
  trap('INT') { server.stop }

  server.run
end
