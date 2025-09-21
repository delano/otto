# frozen_string_literal: true

# lib/otto/helpers/base.rb

class Otto
  # Base helper methods providing core functionality for Otto applications
  module BaseHelpers
    # Build application path by joining path segments
    #
    # This method safely joins multiple path segments, handling
    # duplicate slashes and ensuring proper path formatting.
    # Includes the script name (mount point) as the first segment.
    #
    # @param paths [Array<String>] Path segments to join
    # @return [String] Properly formatted path
    #
    # @example
    #   app_path('api', 'v1', 'users')
    #   # => "/myapp/api/v1/users"
    #
    # @example
    #   app_path(['admin', 'settings'])
    #   # => "/myapp/admin/settings"
    def app_path(*paths)
      paths = paths.flatten.compact
      paths.unshift(req.env['SCRIPT_NAME']) if req.env['SCRIPT_NAME']
      paths.join('/').gsub('//', '/')
    end
  end
end
