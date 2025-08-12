# lib/otto/helpers/validation.rb

class Otto
  module Security
    module ValidationHelpers

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
          if looks_like_script_injection?(input_str)
            raise Otto::Security::ValidationError, 'Dangerous content detected'
          end

          # Use Loofah to sanitize less dangerous HTML content
          sanitized_input = Loofah.fragment(input_str).scrub!(:whitewash).to_s
          input_str       = sanitized_input
        end

        # Always check for SQL injection
        ValidationMiddleware::SQL_INJECTION_PATTERNS.each do |pattern|
          if input_str.match?(pattern)
            raise Otto::Security::ValidationError, 'Potential SQL injection detected'
          end
        end

        input_str
      end

      def sanitize_filename(filename)
        return nil if filename.nil?
        return 'file' if filename.empty?

        # Use Facets File.sanitize for basic filesystem-safe filename
        clean_name = File.sanitize(filename.to_s)

        # Handle edge cases and improve on Facets behavior to match test expectations
        if clean_name.nil? || clean_name.empty?
          clean_name = 'file'
        else
          # Additional cleanup that Facets doesn't do but our tests expect
          clean_name = clean_name.gsub(/_{2,}/, '_')        # Collapse multiple underscores
          clean_name = clean_name.gsub(/^_+|_+$/, '')       # Remove leading/trailing underscores
          clean_name = 'file' if clean_name.empty?          # Handle case where only underscores remain
        end

        # Ensure reasonable length (255 is filesystem limit, leave some padding)
        clean_name = clean_name[0..99] if clean_name.length > 100

        clean_name
      end

      private

      # Check if content looks like it contains HTML tags or entities
      def contains_html_like_content?(content)
        content.match?(/[<>&]/) || content.match?(/&\w+;/)
      end

      # Detect likely script injection attempts that should be rejected
      def looks_like_script_injection?(content)
        dangerous_patterns = [
          /javascript:/i,
          /<script[^>]*>/i,
          /on\w+\s*=/i,  # event handlers like onclick=
          /expression\s*\(/i,
          /data:.*base64/i,
        ]

        dangerous_patterns.any? { |pattern| content.match?(pattern) }
      end

    end
  end
end
