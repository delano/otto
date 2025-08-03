# lib/otto/helpers/base.rb

class Otto
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
      paths.unshift(env['SCRIPT_NAME']) if env['SCRIPT_NAME']
      paths.join('/').gsub('//', '/')
    end

  end
end
