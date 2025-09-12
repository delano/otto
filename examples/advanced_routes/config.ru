# frozen_string_literal: true

# Load the app from our shared config file.
# This returns a configured Otto instance.
app = require_relative 'config'

run app
