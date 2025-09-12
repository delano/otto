#!/usr/bin/env ruby
# frozen_string_literal: true

require 'webrick'
require_relative 'config'

# Create a simple WEBrick server
server = WEBrick::HTTPServer.new(
  Port: 9292,
  Logger: WEBrick::Log.new($stdout, WEBrick::Log::INFO)
)

# Mount the Otto app
server.mount '/', WEBrick::HTTPServlet::ProcHandler.new(proc { |req, res|
  env = req.meta_vars.merge({
    'REQUEST_METHOD' => req.request_method,
    'PATH_INFO' => req.path_info,
    'QUERY_STRING' => req.query_string || '',
    'rack.input' => StringIO.new(req.body || ''),
    'CONTENT_TYPE' => req.content_type,
    'CONTENT_LENGTH' => req.content_length&.to_s
  })

  status, headers, body = otto.call(env)

  res.status = status
  headers.each { |k, v| res[k] = v }
  body.each { |chunk| res.body << chunk }
})

# Handle Ctrl+C gracefully
trap('INT') { server.shutdown }

puts "Otto Advanced Routes Example running on http://localhost:9292"
puts "Press Ctrl+C to stop"

server.start
