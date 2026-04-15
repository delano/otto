# lib/otto/helpers/validation.rb
#
# frozen_string_literal: true

require 'loofah'

class Otto
  module Security
    # Validation helper methods providing input validation and sanitization
    module ValidationHelpers
      # Replace filesystem-unsafe characters with an underscore. Borrowed
      # verbatim from facets 3.1.0's `File.sanitize` (lib/core/facets/file/
      # sanitize.rb, credit: George Moschovitis) and inlined here so Otto
      # doesn't take a runtime dep on the whole facets grab-bag for one
      # 12-line function. See commit message for 2.0.2 for context.
      FILENAME_SANITIZE_PATTERN = /[^a-zA-Z0-9.\-+_]/
      FILENAME_DOT_ONLY         = /^\.+$/
      private_constant :FILENAME_SANITIZE_PATTERN, :FILENAME_DOT_ONLY

      def validate_input(input, max_length: 1000, allow_html: false)
        return input if input.nil?

        input_str = input.to_s
        return input_str if input_str.empty?

        # Check length
        if input_str.length > max_length
          raise Otto::Security::ValidationError, "Input too long (#{input_str.length} > #{max_length})"
        end

        # Use Loofah for HTML sanitization and validation
        unless allow_html
          # Check for script injection first (these should always be rejected)
          raise Otto::Security::ValidationError, 'Dangerous content detected' if looks_like_script_injection?(input_str)

          # Use Loofah to sanitize less dangerous HTML content
          sanitized_input = Loofah.fragment(input_str).scrub!(:whitewash).to_s
          input_str       = sanitized_input
        end

        # Always check for SQL injection
        ValidationMiddleware::SQL_INJECTION_PATTERNS.each do |pattern|
          raise Otto::Security::ValidationError, 'Potential SQL injection detected' if input_str.match?(pattern)
        end

        input_str
      end

      def sanitize_filename(filename)
        return nil if filename.nil?
        return 'file' if filename.empty?

        clean_name = basic_filename_sanitize(filename.to_s)

        if clean_name.nil? || clean_name.empty?
          clean_name = 'file'
        else
          clean_name = clean_name.gsub(/_{2,}/, '_')
          clean_name = clean_name.gsub(/^_+|_+$/, '')
          clean_name = 'file' if clean_name.empty?
        end

        clean_name = clean_name[0..99] if clean_name.length > 100

        clean_name
      end

      private

      # Filesystem-safe basename. Port of facets 3.1.0's `File.sanitize`:
      # strip directory components (handling backslashes for IE-uploaded
      # paths), replace anything outside [A-Za-z0-9.\-+_] with '_', and
      # prefix a leading '_' if the whole name is just dots ('.', '..').
      def basic_filename_sanitize(filename)
        name = File.basename(filename.gsub('\\', '/'))
        name = name.gsub(FILENAME_SANITIZE_PATTERN, '_')
        name = "_#{name}" if name.match?(FILENAME_DOT_ONLY)
        name
      end

      # Check if content looks like it contains HTML tags or entities
      def contains_html_like_content?(content)
        content.match?(/[<>&]/) || content.match?(/&\w+;/)
      end

      # Detect likely script injection attempts that should be rejected
      def looks_like_script_injection?(content)
        dangerous_patterns = [
          /javascript:/i,
          /<script[^>]*>/i,
          /on\w+\s*=/i, # event handlers like onclick=
          /expression\s*\(/i,
          /data:.*base64/i,
        ]

        dangerous_patterns.any? { |pattern| content.match?(pattern) }
      end
    end
  end
end
