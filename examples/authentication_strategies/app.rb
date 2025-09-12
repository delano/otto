# frozen_string_literal: true

# Load all controllers
Dir[File.join(__dir__, 'app/controllers', '*.rb')].each { |file| require_relative file }

# Load all logic classes
Dir[File.join(__dir__, 'app/logic', '**', '*.rb')].each { |file| require_relative file }
