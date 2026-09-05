# lib/otto/core/file_safety.rb
#
# frozen_string_literal: true

class Otto
  module Core
    # File safety module providing secure file access validation and path traversal protection.
    #
    # Symlink policy (issue #257)
    # ---------------------------
    # Every candidate path is canonicalized with File.realpath before it is
    # compared against the canonicalized public root. A symlink inside the
    # public directory is therefore served ONLY when its fully resolved target
    # (including every intermediate directory component) is still inside that
    # root. Links that escape the root are rejected even when the target is
    # owned by the same user or group -- the ownership check is a second gate,
    # not a containment gate.
    #
    # The root itself is canonicalized too, so a symlinked public directory
    # (the usual `public -> releases/<n>/public` deploy layout) keeps working.
    #
    # Missing, unreadable, looping and non-directory-component paths all fail
    # closed: realpath raises and the raise is treated as "unsafe".
    module FileSafety
      # Errors raised by File.realpath for paths that must never be served.
      REALPATH_ERRORS = [
        Errno::ENOENT,       # missing target (dangling symlink)
        Errno::EACCES,       # unreadable component
        Errno::ELOOP,        # symlink loop
        Errno::ENOTDIR,      # a path component is not a directory
        Errno::ENAMETOOLONG, # oversized path
      ].freeze

      # A validated static file: the canonical root, the canonical absolute
      # path under it, and their relative difference. Returned as one value so
      # callers never have to re-run realpath (one resolution per request).
      StaticFile = Struct.new(:root, :path, :relative)

      # Resolve a request path to a canonical, contained, servable file.
      #
      # @param path [String, nil] request-relative path (may start with '/')
      # @return [StaticFile, nil] the validated file, or nil when unsafe
      def resolve_static_file(path)
        return nil if option[:public].nil? || option[:public].empty?
        return nil if path.nil? || path.empty?

        public_dir = canonical_public_dir
        return nil if public_dir.nil?

        # A NUL byte in a request path is never legitimate; it is a truncation
        # attack on downstream C string handling. Reject it rather than
        # repairing the path into something servable.
        return nil if path.include?("\0")

        clean_path = path.strip
        return nil if clean_path.empty?

        # Join, then canonicalize: realpath resolves '..', '.' AND every
        # symlink component, so the containment check below cannot be fooled
        # by a link that points outside the public directory.
        candidate = File.join(public_dir, clean_path)
        real_path = safe_realpath(candidate)
        return nil if real_path.nil?

        return nil unless contained?(real_path, public_dir)

        # Second gate: it must be a readable regular file we (or our group) own.
        return nil unless File.file?(real_path) && File.readable?(real_path)
        return nil unless File.owned?(real_path) || File.grpowned?(real_path)

        StaticFile.new(public_dir, real_path, real_path.delete_prefix(public_dir + File::SEPARATOR))
      end

      def safe_file?(path)
        !resolve_static_file(path).nil?
      end

      def safe_dir?(path)
        return false if path.nil? || path.empty?

        # Clean and expand the path
        clean_path = path.delete("\0").strip
        return false if clean_path.empty?

        real_path = safe_realpath(clean_path)
        return false if real_path.nil?

        # Check directory exists, is readable, and has proper ownership
        File.directory?(real_path) &&
          File.readable?(real_path) &&
          (File.owned?(real_path) || File.grpowned?(real_path))
      end

      private

      # Canonical public root, or nil when it is missing/not a directory.
      # Not memoized: the root can be replaced (deploy symlink flip) between
      # requests and each request must see the current target.
      def canonical_public_dir
        real = safe_realpath(option[:public])
        return nil if real.nil? || !File.directory?(real)

        real
      end

      def safe_realpath(path)
        File.realpath(path)
      rescue *REALPATH_ERRORS, SystemCallError, ArgumentError
        nil
      end

      # Component-aware containment: '/srv/public2' must not pass for the
      # root '/srv/public', so compare on a separator boundary.
      def contained?(real_path, root)
        real_path == root || real_path.start_with?(root + File::SEPARATOR)
      end
    end
  end
end
