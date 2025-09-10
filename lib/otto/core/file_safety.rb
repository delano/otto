# frozen_string_literal: true
# lib/otto/core/file_safety.rb

class Otto
  module Core
    module FileSafety
      def safe_file?(path)
        return false if option[:public].nil? || option[:public].empty?
        return false if path.nil? || path.empty?

        # Normalize and resolve the public directory path
        public_dir = File.expand_path(option[:public])
        return false unless File.directory?(public_dir)

        # Clean the requested path - remove null bytes and normalize
        clean_path = path.delete("\0").strip
        return false if clean_path.empty?

        # Join and expand to get the full resolved path
        requested_path = File.expand_path(File.join(public_dir, clean_path))

        # Ensure the resolved path is within the public directory (prevents path traversal)
        return false unless requested_path.start_with?(public_dir + File::SEPARATOR)

        # Check file exists, is readable, and is not a directory
        File.exist?(requested_path) &&
          File.readable?(requested_path) &&
          !File.directory?(requested_path) &&
          (File.owned?(requested_path) || File.grpowned?(requested_path))
      end

      def safe_dir?(path)
        return false if path.nil? || path.empty?

        # Clean and expand the path
        clean_path = path.delete("\0").strip
        return false if clean_path.empty?

        expanded_path = File.expand_path(clean_path)

        # Check directory exists, is readable, and has proper ownership
        File.directory?(expanded_path) &&
          File.readable?(expanded_path) &&
          (File.owned?(expanded_path) || File.grpowned?(expanded_path))
      end

      def add_static_path(path)
        return unless safe_file?(path)

        base_path                      = File.split(path).first
        # Files in the root directory can refer to themselves
        base_path                      = path if base_path == '/'
        File.join(option[:public], base_path)
        Otto.logger.debug "new static route: #{base_path} (#{path})" if Otto.debug
        routes_static[:GET][base_path] = base_path
      end
    end
  end
end
