# lib/otto/core/static_mounts.rb
#
# frozen_string_literal: true

require 'rack/files'

class Otto
  module Core
    # Explicit static-file registration (issue #267).
    #
    # A static mount binds a URL prefix to one directory on disk:
    #
    #   otto.mount_static('/assets', root: 'public/assets')
    #
    # Requests for GET /assets/<rest> are then resolved against
    # public/assets/<rest> using the same containment policy as the implicit
    # +public:+ directory (Otto::Core::FileSafety): the candidate is
    # canonicalized with File.realpath and must land inside the mount's
    # canonical root, be a regular readable file, and be owned by the process
    # user or group. A mount never authorizes anything outside its own root,
    # so several mounts can point into unrelated directories without exposing
    # their parents or siblings.
    #
    # Registration is a boot-time operation. The root is canonicalized once,
    # when the mount is registered, and every failure mode (missing,
    # unreadable, not a directory, escaping symlink, malformed prefix,
    # duplicate prefix) raises ArgumentError immediately so a misconfigured
    # application does not start. Mounts participate in configuration
    # freezing: mount_static raises FrozenError after freeze_configuration!,
    # and the mount table is an immutable, sorted snapshot that dispatch reads
    # without any per-request mutation.
    #
    # Dispatch precedence is fixed: literal routes, then static mounts (longest
    # prefix first), then the implicit +public:+ directory, then dynamic
    # routes. A mount claims files, not the prefix: when no mount root
    # contains the requested file the request falls through to the next
    # stage exactly as an unregistered path would. See Otto::Core::Router.
    module StaticMounts
      # One registered mount. +prefix+ is the normalized URL prefix ('' for a
      # root mount), +root+ the canonical directory, +files+ the Rack::Files
      # instance rooted there. Instances are frozen at construction.
      StaticMount = Struct.new(:prefix, :root, :files) do
        # Request-relative path under this mount, or nil when +path+ is not
        # beneath the prefix. The prefix itself (the directory) never matches:
        # a mount serves files, not directory listings.
        #
        # @param path [String] normalized dispatch path (leading '/')
        # @return [String, nil]
        def relative_path_for(path)
          if prefix.empty?
            path
          elsif path.start_with?("#{prefix}/")
            path[(prefix.length + 1)..]
          end
        end

        # Prefix as an operator would write it ('/' for a root mount).
        def display_prefix
          prefix.empty? ? '/' : prefix
        end
      end

      # Registered mounts, longest prefix first. Frozen snapshot; a new array
      # replaces it on every registration so readers never observe a partial
      # update.
      #
      # @return [Array<StaticMount>]
      def static_mounts
        @static_mounts
      end

      # Serve the files under +root+ at URLs beneath +prefix+.
      #
      # @param prefix [String] URL prefix starting with '/'. A trailing slash
      #   is ignored; '/' mounts the root at the top level.
      # @param root [String] directory path; relative paths resolve against
      #   the process working directory and are canonicalized immediately.
      # @return [StaticMount] the registered mount
      # @raise [ArgumentError] on a malformed prefix, a duplicate prefix, or a
      #   root that is missing, unreadable, not a directory, not owned by the
      #   process user or group, or that cannot be canonicalized.
      # @raise [FrozenError] after configuration freezing
      def mount_static(prefix, root:)
        ensure_not_frozen!

        clean_prefix = normalize_mount_prefix(prefix)
        if @static_mounts.any? { |mount| mount.prefix == clean_prefix }
          raise ArgumentError,
                "Static mount prefix #{display_mount_prefix(clean_prefix).inspect} is already registered"
        end

        canonical_root = canonicalize_mount_root(clean_prefix, root)
        mount = StaticMount.new(clean_prefix, canonical_root, Rack::Files.new(canonical_root).freeze).freeze

        # Longest prefix first so an overlay ('/assets/vendor') is consulted
        # before the mount that contains it ('/assets'). Ties cannot happen:
        # prefixes are unique. Rebuild rather than mutate so in-flight readers
        # keep their snapshot.
        @static_mounts = (@static_mounts + [mount]).sort_by { |m| -m.prefix.length }.freeze

        Otto.structured_log(:debug, 'Static mount registered',
          { prefix: mount.display_prefix, root: mount.root })
        mount
      end

      private

      # Resolve +path+ through the registered mounts, longest prefix first.
      # Read-only: safe to call from concurrent request threads.
      #
      # @param path [String] normalized dispatch path (leading '/')
      # @return [Array(StaticMount, Otto::Core::FileSafety::StaticFile), nil]
      def resolve_mounted_file(path)
        @static_mounts.each do |mount|
          relative = mount.relative_path_for(path)
          next if relative.nil?

          static_file = resolve_file_under(mount.root, relative)
          return [mount, static_file] if static_file
        end
        nil
      end

      # Validate and normalize a mount prefix. Returns '' for the root mount
      # and a leading-slash, no-trailing-slash prefix otherwise, matching the
      # normalized request path the router compares against.
      def normalize_mount_prefix(prefix)
        raise ArgumentError, "Static mount prefix must be a String, got #{prefix.class}" unless prefix.is_a?(String)
        raise ArgumentError, "Static mount prefix #{prefix.inspect} contains a NUL byte" if prefix.include?("\0")
        raise ArgumentError, "Static mount prefix #{prefix.inspect} must start with '/'" unless prefix.start_with?('/')

        clean = prefix.sub(%r{/+\z}, '')
        return '' if clean.empty?

        segments = clean.split('/', -1).drop(1)
        if segments.any? { |segment| segment.empty? || segment == '.' || segment == '..' }
          raise ArgumentError,
                "Static mount prefix #{prefix.inspect} must not contain empty, '.', or '..' segments"
        end

        clean.freeze
      end

      # Canonicalize a mount root under Otto's static-file safety policy and
      # fail loudly on anything that could not be served safely.
      def canonicalize_mount_root(prefix, root)
        label = "Static mount #{display_mount_prefix(prefix).inspect}"
        raise ArgumentError, "#{label} root must be a String, got #{root.class}" unless root.is_a?(String)
        raise ArgumentError, "#{label} root must not be empty" if root.strip.empty?
        raise ArgumentError, "#{label} root #{root.inspect} contains a NUL byte" if root.include?("\0")

        real = safe_realpath(File.expand_path(root))
        if real.nil?
          raise ArgumentError,
                "#{label} root #{root.inspect} cannot be resolved " \
                '(missing, unreadable component, or symlink loop)'
        end
        raise ArgumentError, "#{label} root #{root.inspect} is not a directory" unless File.directory?(real)
        raise ArgumentError, "#{label} root #{root.inspect} is not readable" unless File.readable?(real)

        owned = File.owned?(real) || File.grpowned?(real)
        raise ArgumentError, "#{label} root #{root.inspect} is not owned by the process user or group" unless owned

        real.freeze
      end

      def display_mount_prefix(prefix)
        prefix.empty? ? '/' : prefix
      end
    end
  end
end
