# frozen_string_literal: true

# Base error classes for Otto framework
#
# These classes provide a foundation for HTTP error handling and can be
# subclassed by implementing projects for consistent error handling.
#
# @example Subclassing in an application
#   class MyApp::ResourceNotFound < Otto::NotFoundError; end
#
#   otto.register_error_handler(MyApp::ResourceNotFound, status: 404, log_level: :info)
#
class Otto
  # Base class for all Otto HTTP errors
  #
  # Provides default_status and default_log_level class methods that
  # define the HTTP status code and logging level for the error.
  class HTTPError < StandardError
    def self.default_status
      500
    end

    def self.default_log_level
      :error
    end
  end

  # Bad Request (400) error
  #
  # Use for malformed requests, invalid parameters, or failed validation
  class BadRequestError < HTTPError
    def self.default_status
      400
    end

    def self.default_log_level
      :info
    end
  end

  # Unauthorized (401) error
  #
  # Use when authentication is required but missing or invalid
  class UnauthorizedError < HTTPError
    def self.default_status
      401
    end

    def self.default_log_level
      :info
    end
  end

  # Forbidden (403) error
  #
  # Use when the user is authenticated but lacks permission
  class ForbiddenError < HTTPError
    def self.default_status
      403
    end

    def self.default_log_level
      :warn
    end
  end

  # Not Found (404) error
  #
  # Use when the requested resource does not exist
  class NotFoundError < HTTPError
    def self.default_status
      404
    end

    def self.default_log_level
      :info
    end
  end

  # Payload Too Large (413) error
  #
  # Use when request body exceeds configured size limits
  class PayloadTooLargeError < HTTPError
    def self.default_status
      413
    end

    def self.default_log_level
      :warn
    end
  end
end
