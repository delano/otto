# spec/support/csrf_secret_isolation.rb
#
# frozen_string_literal: true

# Otto::Security::Config reads OTTO_CSRF_SECRET in its constructor and again
# when csrf_secret= receives nil or a blank value, and a short value logs a
# warning. An OTTO_CSRF_SECRET exported in the shell that runs the suite would
# therefore turn generated-secret examples into configured-secret ones and add
# warnings that logger expectations do not allow for. Every example starts
# with the variable unset; an example that needs it sets it and this hook puts
# the shell's value back afterwards.
RSpec.configure do |config|
  config.around do |example|
    original = ENV.delete('OTTO_CSRF_SECRET')
    begin
      example.run
    ensure
      if original.nil?
        ENV.delete('OTTO_CSRF_SECRET')
      else
        ENV['OTTO_CSRF_SECRET'] = original
      end
    end
  end
end
