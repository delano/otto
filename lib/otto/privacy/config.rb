# lib/otto/privacy/config.rb
#
# frozen_string_literal: true

require 'ipaddr'
require 'securerandom'
require 'digest'

require 'concurrent'

require_relative '../core/freezable'
require_relative '../optional_dependency'

class Otto
  module Privacy
    # Configuration for IP privacy features
    #
    # Privacy is ENABLED by default for public IPs. Private/localhost IPs are not masked.
    #
    # @example Default configuration (privacy enabled)
    #   config = Otto::Privacy::Config.new
    #   config.enabled? # => true
    #
    # @example Configure masking level
    #   config = Otto::Privacy::Config.new
    #   config.octet_precision = 2  # Mask 2 octets instead of 1
    #
    # rubocop:disable Metrics/ClassLength -- three parallel database
    # configurations (geo, ASN, anonymizer) live here by design: each is a
    # thin, symmetric writer/reader/loader trio, and splitting them into
    # modules would hide the symmetry that makes them reviewable.
    class Config
      include Otto::Core::Freezable

      MAXMIND_DB_REQUIREMENT = '~> 1.2'

      # Named privacy profiles: validated presets over the individual knobs,
      # so a deployment's observability posture is declared in one reviewable
      # word instead of inferred from knob combinations.
      #
      # - :anonymous — mask every IP, including private/localhost. For
      #   deployments where even internal addresses are treated as PII.
      # - :masked    — the default posture: public IPs masked, private and
      #   localhost exempt (development-friendly privacy-by-default).
      # - :audit     — privacy disabled: real IPs flow to env and logs. For
      #   private/compliance environments where granular attributability
      #   supersedes IP privacy; retention responsibility transfers to the
      #   operator.
      #
      # Note the axis this controls: what PERSISTS observably (env keys, logs,
      # fingerprints). Precise ephemeral matching against the unmasked IP does
      # not require :audit — see EnvKeys::IP_MATCH, available in every profile.
      PROFILES = {
        anonymous: { disabled: false, mask_private_ips: true }.freeze,
           masked: { disabled: false, mask_private_ips: false }.freeze,
            audit: { disabled: true }.freeze,
      }.freeze

      attr_accessor :octet_precision, :hash_rotation_period, :geo_enabled, :mask_private_ips,
                    :asn_enabled, :anonymizer_enabled
      attr_reader :disabled, :correlation_secret, :geo_header, :geo_db_path,
                  :asn_db_path, :anonymizer_db_path

      # Class-level rotation key storage (mutable, not frozen with instances)
      # This is stored at the class level so it persists across frozen config instances
      @rotation_keys_store = nil

      class << self
        # Get the class-level rotation keys store
        # @return [Concurrent::Map] Thread-safe map for rotation keys
        def rotation_keys_store
          @rotation_keys_store = Concurrent::Map.new unless defined?(@rotation_keys_store) && @rotation_keys_store
          @rotation_keys_store
        end
      end

      # Initialize privacy configuration
      #
      # @param options [Hash] Configuration options
      # @option options [Integer] :octet_precision Number of trailing octets to mask (1 or 2, default: 1)
      # @option options [Integer] :hash_rotation_period Seconds between key rotation (default: 86400)
      # @option options [Boolean] :geo_enabled Enable geo-location resolution (default: true)
      # @option options [String] :geo_header Trusted, app-configured request header to read the
      #   country code from FIRST (before the built-in CDN provider headers). Accepts either
      #   the HTTP form ('X-Client-Country') or the Rack CGI form ('HTTP_X_CLIENT_COUNTRY');
      #   both canonicalize to the 'HTTP_*' env key. Default nil (no app-configured header).
      # @option options [String] :geo_db_path Filesystem path to a MaxMind-format (.mmdb)
      #   country database used as the local IP->country fallback (looked up on the already
      #   MASKED IP). Requires the 'maxmind-db' gem. A bad/unreadable path raises at boot,
      #   not per-request. Default nil (no local database fallback).
      # @option options [#get] :geo_db_reader Bring-your-own MMDB reader (any object responding
      #   to #get, e.g. a MaxMind::DB or a compatible reader). Overrides :geo_db_path when set,
      #   so the reader choice stays independent of Otto. Default nil.
      # @option options [Boolean] :asn_enabled Enable ASN resolution (default: FALSE — unlike
      #   :geo_enabled, this signal is opt-in, so a deployment that never asks for it pays
      #   nothing and no database is opened)
      # @option options [String] :asn_db_path Filesystem path to a MaxMind-format (.mmdb) ASN
      #   database (looked up on the already MASKED IP, like the geo database). Requires the
      #   'maxmind-db' gem. A bad/unreadable path raises at boot, not per-request. Default nil.
      # @option options [#get] :asn_db_reader Bring-your-own MMDB reader for ASN lookups (any
      #   object responding to #get). Overrides :asn_db_path when set. Default nil.
      # @option options [Boolean] :anonymizer_enabled Enable anonymizer (Tor/VPN/proxy/hosting)
      #   classification (default: FALSE — opt-in, same as :asn_enabled)
      # @option options [String] :anonymizer_db_path Filesystem path to a MaxMind-format (.mmdb)
      #   anonymous-IP database. Looked up on the UNMASKED IP — anonymizer data lists individual
      #   egress nodes at /32, so a masked lookup would answer for the node's neighbours; only
      #   the resulting label leaves the resolver. Requires the 'maxmind-db' gem. A bad path
      #   raises at boot. Default nil.
      # @option options [#get] :anonymizer_db_reader Bring-your-own MMDB reader for anonymizer
      #   lookups (any object responding to #get). Overrides :anonymizer_db_path. Default nil.
      # @option options [Boolean] :disabled Disable privacy entirely (default: false)
      # @option options [Boolean] :mask_private_ips Mask private/localhost IPs (default: false)
      # @option options [String] :correlation_secret A secret string that turns
      #   on IP correlation. Default nil, meaning off.
      #
      #   It answers one question: "are these two requests, maybe months apart,
      #   from the same visitor?" — without your app ever seeing the real IP.
      #
      #   Otto masks each IP before your app runs (203.0.113.42 becomes
      #   203.0.113.0), which is too coarse to tell visitors apart. When a secret
      #   is set, Otto also fingerprints the full IP, before masking, and hands
      #   your app just the fingerprint as req.ip_correlation_hash. The same IP
      #   always produces the same fingerprint, and it can't be turned back into
      #   an IP without the secret.
      #
      #   Keep the secret stable — changing it changes every fingerprint. An empty
      #   string is rejected, because an empty secret would let anyone reverse the
      #   fingerprint back to an IP.
      # @option options [Redis] :redis Optional Redis connection for multi-server environments
      # @option options [Symbol, String] :profile Named privacy profile (:anonymous,
      #   :masked, or :audit) applied as a preset; any other explicitly passed
      #   option overrides the preset. See {PROFILES}.
      def initialize(options = {})
        options = self.class.profile_presets(options[:profile]).merge(options) unless options[:profile].nil?
        @octet_precision = options.fetch(:octet_precision, 1)
        @hash_rotation_period = options.fetch(:hash_rotation_period, 86_400) # 24 hours
        @geo_enabled = options.fetch(:geo_enabled, true)
        @disabled = options.fetch(:disabled, false) # Enabled by default (privacy-by-default)
        @mask_private_ips = options.fetch(:mask_private_ips, false) # Don't mask private/localhost by default
        self.correlation_secret = options.fetch(:correlation_secret, nil) # Opt-in stable IP-correlation secret
        @redis = options[:redis] # Optional Redis connection for multi-server environments

        # Geo-location fallback configuration (all opt-in, boot-time only).
        @geo_db_reader = nil # effective MMDB reader (built from path or injected)
        @geo_db_override = nil # reader injected via geo_db_reader= (wins over path)
        self.geo_header = options[:geo_header] # canonicalized to an HTTP_* env key (or nil)
        self.geo_db_reader = options[:geo_db_reader] if options.key?(:geo_db_reader)
        @geo_db_path = normalize_db_path(options[:geo_db_path])
        load_geo_database! # build/attach the reader now so a bad path fails at boot

        # ASN enrichment (opt-in, boot-time only). Same two-ivar shape as geo.
        @asn_enabled = options.fetch(:asn_enabled, false)
        @asn_db_reader = nil
        @asn_db_override = nil
        self.asn_db_reader = options[:asn_db_reader] if options.key?(:asn_db_reader)
        @asn_db_path = normalize_db_path(options[:asn_db_path])
        load_asn_database!

        # Anonymizer classification (opt-in, boot-time only).
        @anonymizer_enabled = options.fetch(:anonymizer_enabled, false)
        @anonymizer_db_reader = nil
        @anonymizer_db_override = nil
        self.anonymizer_db_reader = options[:anonymizer_db_reader] if options.key?(:anonymizer_db_reader)
        @anonymizer_db_path = normalize_db_path(options[:anonymizer_db_path])
        load_anonymizer_database!
      end

      # Set the stable correlation secret, validating its type up front.
      #
      # nil or an empty string mean "correlation hash disabled" (see
      # IPPrivacyMiddleware#correlation_hash — an empty key is never used to
      # hash). Any other non-String is a configuration error: without this
      # guard it would surface far from its cause, as a NoMethodError on
      # `#empty?` deep inside per-request middleware. Fail fast here instead,
      # at the point of misconfiguration, with a message that names the type.
      #
      # @param value [String, nil] stable secret, or nil/"" to disable
      # @raise [ArgumentError] if value is neither a String nor nil
      def correlation_secret=(value)
        unless value.nil? || value.is_a?(String)
          raise ArgumentError, "correlation_secret must be a String or nil, got: #{value.class}"
        end

        @correlation_secret = value
      end

      # Set the trusted, app-configured geo header.
      #
      # Canonicalizes to a Rack CGI env key ('HTTP_*'): 'X-Client-Country',
      # 'x-client-country' and 'HTTP_X_CLIENT_COUNTRY' all become
      # 'HTTP_X_CLIENT_COUNTRY'. nil / blank clears it. Rack 3's lowercase rule
      # applies to RESPONSE headers; request headers remain 'HTTP_*' env keys,
      # so this is the correct form to read from the request env.
      #
      # @param value [String, nil] header name in either HTTP or CGI form
      def geo_header=(value)
        @geo_header = self.class.canonicalize_geo_header(value)
      end

      # Set the geo database path (MMDB file) used for the local fallback.
      #
      # Does not build the reader on its own — call {#load_geo_database!} (which
      # {Otto::Privacy::Core#configure_ip_privacy} does for you) so a bad path
      # fails at boot rather than per-request.
      #
      # @param value [String, nil] filesystem path to a .mmdb file, or nil
      def geo_db_path=(value)
        @geo_db_path = normalize_db_path(value)
      end

      # Path to a MaxMind-format ASN database. See {#geo_db_path=}; the same
      # boot-time contract applies — call {#load_asn_database!} to attach it.
      #
      # @param value [String, nil] filesystem path to a .mmdb file, or nil
      def asn_db_path=(value)
        @asn_db_path = normalize_db_path(value)
      end

      # Path to a MaxMind-format anonymous-IP database. See {#geo_db_path=};
      # call {#load_anonymizer_database!} to attach it.
      #
      # @param value [String, nil] filesystem path to a .mmdb file, or nil
      def anonymizer_db_path=(value)
        @anonymizer_db_path = normalize_db_path(value)
      end

      # Replace one enrichment database path only after its new reader has
      # opened successfully. Used by the boot-time configuration path; direct
      # callers should normally use Otto#configure_ip_privacy.
      #
      # @param prefix [:asn, :anonymizer] database source to replace
      # @param value [String, nil] new database path
      # @return [void]
      # @raise [ArgumentError] if an enabled signal's path cannot be opened
      # @api private
      def replace_enrichment_database_path!(prefix, value)
        path = normalize_db_path(value)
        enabled = instance_variable_get(:"@#{prefix}_enabled")
        reader = path && enabled ? build_maxmind_reader(path, option_name: "#{prefix}_db_path") : nil

        instance_variable_set(:"@#{prefix}_db_path", path)
        instance_variable_set(:"@#{prefix}_db_override", nil)
        instance_variable_set(:"@#{prefix}_db_reader", reader)
      end

      # Inject a ready-made MMDB reader (any object responding to #get).
      #
      # This keeps the reader choice independent of Otto (MaxMind::DB, yhirose's
      # maxminddb, or a custom object all work) and is the seam used by tests.
      # When set, it takes precedence over {#geo_db_path}. Passing nil clears the
      # override. Takes effect on the next {#load_geo_database!}.
      #
      # @param reader [#get, nil] MMDB-compatible reader, or nil to clear
      # @raise [ArgumentError] if reader does not respond to :get
      def geo_db_reader=(reader)
        unless reader.nil? || reader.respond_to?(:get)
          raise ArgumentError, "geo_db_reader must respond to :get, got: #{reader.class}"
        end

        @geo_db_override = reader
      end

      # The effective MMDB reader for this config, or nil.
      #
      # Returns nil when geo is disabled (so `geo: false` consults no database
      # even if one was previously configured) or when neither a reader override
      # nor a database path is set.
      #
      # The reader is a plain instance variable — no class-level store. A
      # MaxMind::DB reader computes its IPv4 start node eagerly at construction
      # and performs no instance mutation on #get, so it is thread-safe under
      # concurrency and unaffected by the shallow freeze deep_freeze! applies to
      # it. That removes the only reason to hold it off-instance, and avoids an
      # unbounded, never-evicted process-lifetime cache — important for a
      # long-running server.
      #
      # @return [#get, nil] the reader, or nil
      def geo_db_reader
        @geo_enabled ? @geo_db_reader : nil
      end

      # Inject a ready-made MMDB reader for ASN lookups. See {#geo_db_reader=}.
      #
      # @param reader [#get, nil] MMDB-compatible reader, or nil to clear
      # @raise [ArgumentError] if reader does not respond to :get
      def asn_db_reader=(reader)
        unless reader.nil? || reader.respond_to?(:get)
          raise ArgumentError, "asn_db_reader must respond to :get, got: #{reader.class}"
        end

        @asn_db_override = reader
      end

      # The effective ASN reader, or nil when ASN resolution is off.
      #
      # @return [#get, nil]
      def asn_db_reader
        @asn_enabled ? @asn_db_reader : nil
      end

      # Inject a ready-made MMDB reader for anonymizer lookups.
      # See {#geo_db_reader=}.
      #
      # @param reader [#get, nil] MMDB-compatible reader, or nil to clear
      # @raise [ArgumentError] if reader does not respond to :get
      def anonymizer_db_reader=(reader)
        unless reader.nil? || reader.respond_to?(:get)
          raise ArgumentError, "anonymizer_db_reader must respond to :get, got: #{reader.class}"
        end

        @anonymizer_db_override = reader
      end

      # The effective anonymizer reader, or nil when classification is off.
      #
      # @return [#get, nil]
      def anonymizer_db_reader
        @anonymizer_enabled ? @anonymizer_db_reader : nil
      end

      # Build/attach the geo database reader for the current configuration.
      #
      # Boot-time only. Resolves the effective reader (injected override wins
      # over a path). A String path is opened eagerly here so an unreadable path
      # or a missing 'maxmind-db' gem raises now, at configuration time, rather
      # than on the first request that needs a lookup. When geo is disabled, no
      # database is loaded and no reader is retained.
      #
      # @return [void]
      # @raise [ArgumentError] if the path is unreadable or maxmind-db is absent
      def load_geo_database!
        @geo_db_reader = nil
        return unless @geo_enabled

        @geo_db_reader =
          if @geo_db_override
            @geo_db_override
          elsif @geo_db_path
            build_maxmind_reader(@geo_db_path)
          end
      end

      # Build/attach the ASN database reader. See {#load_geo_database!} — same
      # boot-time contract, same override-wins-over-path resolution.
      #
      # @return [void]
      # @raise [ArgumentError] if the path is unreadable or maxmind-db is absent
      def load_asn_database!
        @asn_db_reader = nil
        return unless @asn_enabled

        @asn_db_reader =
          if @asn_db_override
            @asn_db_override
          elsif @asn_db_path
            build_maxmind_reader(@asn_db_path, option_name: 'asn_db_path')
          end
      end

      # Build/attach the anonymizer database reader. See {#load_geo_database!}.
      #
      # @return [void]
      # @raise [ArgumentError] if the path is unreadable or maxmind-db is absent
      def load_anonymizer_database!
        @anonymizer_db_reader = nil
        return unless @anonymizer_enabled

        @anonymizer_db_reader =
          if @anonymizer_db_override
            @anonymizer_db_override
          elsif @anonymizer_db_path
            build_maxmind_reader(@anonymizer_db_path, option_name: 'anonymizer_db_path')
          end
      end

      # Look up the preset hash for a named profile, failing fast on typos.
      #
      # @param profile [Symbol, String] one of the {PROFILES} keys
      # @return [Hash] frozen preset hash
      # @raise [ArgumentError] for an unknown profile name or an un-nameable type
      def self.profile_presets(profile)
        # Neither Integer nor NilClass responds to #to_sym, so an unguarded
        # conversion raises NoMethodError for `profile: 123` or an explicit
        # `profile: nil` — an opaque failure inconsistent with the ArgumentError
        # the rest of this class raises for bad input (cf. correlation_secret=).
        unless profile.respond_to?(:to_sym)
          raise ArgumentError,
                "Privacy profile must be a Symbol or String, got: #{profile.class}"
        end

        PROFILES.fetch(profile.to_sym) do
          raise ArgumentError,
                "Unknown privacy profile: #{profile.inspect} (valid: #{PROFILES.keys.join(', ')})"
        end
      end

      # Apply a named privacy profile's presets to this config.
      #
      # Sets only the knobs the profile names (see {PROFILES}); other settings
      # (octet_precision, geo, correlation_secret, ...) are untouched.
      #
      # Presets are applied, not reset: a knob a profile does not name keeps its
      # previous value. Switching :anonymous -> :audit therefore leaves
      # mask_private_ips true, because :audit names only `disabled`. That is
      # inert rather than wrong — `disabled` short-circuits privacy_enabled?
      # before mask_private_ips is ever read, and #profile below tests @disabled
      # first, so the derived label stays accurate. Switching on to :masked
      # re-sets both knobs explicitly. Only surprising if you read the raw ivars.
      #
      # @param profile [Symbol, String] :anonymous, :masked, or :audit
      # @raise [ArgumentError] for an unknown profile name
      def profile=(profile)
        presets = self.class.profile_presets(profile)
        @disabled = presets[:disabled] if presets.key?(:disabled)
        @mask_private_ips = presets[:mask_private_ips] if presets.key?(:mask_private_ips)
      end

      # The profile the current knob state corresponds to.
      #
      # Derived from the live settings rather than remembering the last
      # `profile=` call, so manual knob changes can never leave a stale label:
      # what this returns is always what the config actually does.
      #
      # @return [Symbol] :audit, :anonymous, or :masked
      def profile
        return :audit if @disabled
        return :anonymous if @mask_private_ips

        :masked
      end

      # Canonicalize a geo header name to a Rack CGI env key ('HTTP_*').
      #
      # @param value [String, nil] header in HTTP ('X-Client-Country') or CGI form
      # @return [String, nil] 'HTTP_*' env key, or nil for nil/blank input
      def self.canonicalize_geo_header(value)
        return nil if value.nil?

        key = value.to_s.strip
        return nil if key.empty?

        key = key.upcase.tr('-', '_')
        key.start_with?('HTTP_') ? key : "HTTP_#{key}"
      end

      # Check if privacy is enabled
      #
      # @return [Boolean] true if privacy is enabled (default)
      def enabled?
        !@disabled
      end

      # Check if privacy is disabled
      #
      # @return [Boolean] true if privacy was explicitly disabled
      def disabled?
        @disabled
      end

      # Disable privacy (allows access to original IPs)
      #
      # IMPORTANT: This should only be used when you have a specific
      # requirement to access original IP addresses. By default, Otto
      # provides privacy-safe masked IPs.
      #
      # @return [self]
      def disable!
        @disabled = true
        self
      end

      # Enable privacy (default state)
      #
      # @return [self]
      def enable!
        @disabled = false
        self
      end

      # Get the current rotation key for IP hashing
      #
      # Keys rotate at fixed intervals based on hash_rotation_period (default: 24 hours).
      # Each rotation period gets a unique key, ensuring IP addresses hash differently
      # across periods while remaining consistent within.
      #
      # Multi-server support:
      # - With Redis: Uses SET NX GET EX for atomic key generation across all servers
      # - Without Redis: Falls back to in-memory Concurrent::Hash (single-server only)
      #
      # Redis keys:
      #   - rotation_key:{timestamp} - Stores the rotation key with TTL
      #
      # @return [String] Current rotation key for hashing
      def rotation_key
        if @redis
          rotation_key_redis
        else
          rotation_key_memory
        end
      end

      # Validate configuration settings
      #
      # @raise [ArgumentError] if configuration is invalid
      def validate!
        raise ArgumentError, "octet_precision must be 1 or 2, got: #{@octet_precision}" unless [1,
                                                                                                2].include?(@octet_precision)

        # Type check before the numeric comparison: a non-Numeric value (false,
        # a String from unparsed config, ...) would otherwise surface as
        # NoMethodError/ArgumentError from #<, not a clear configuration error.
        return if @hash_rotation_period.is_a?(Numeric) && @hash_rotation_period >= 60

        raise ArgumentError,
              "hash_rotation_period must be at least 60 seconds, got: #{@hash_rotation_period.inspect}"
      end

      private

      # Normalize a database-path option to a non-empty String or nil. Shared by
      # the geo, ASN and anonymizer paths — the rule is identical for all three.
      #
      # @param value [String, nil] raw path option
      # @return [String, nil]
      def normalize_db_path(value)
        return nil if value.nil?

        path = value.to_s.strip
        path.empty? ? nil : path
      end

      # Open an MMDB file into an in-memory reader, failing fast on problems.
      #
      # The 'maxmind-db' gem is an OPTIONAL dependency: it is required lazily
      # here, only when a database path is actually configured, so Otto stays
      # dependency-light for the (common) header-only geo setups. Callers who
      # prefer a different reader can inject one via {#geo_db_reader=} and never
      # trigger this path.
      #
      # @param path [String] filesystem path to a .mmdb file
      # @return [MaxMind::DB] in-memory reader
      # @raise [ArgumentError] if the path is unreadable or the gem is missing
      def build_maxmind_reader(path, option_name: 'geo_db_path')
        raise ArgumentError, "#{option_name} is not readable: #{path.inspect}" unless File.readable?(path)

        Otto::OptionalDependency.require!(
          'maxmind-db',
          MAXMIND_DB_REQUIREMENT,
          require_path: 'maxmind/db',
          feature: "#{option_name} database loading",
          alternative: "Or inject a reader with `#{option_name.sub('_path', '_reader')}:`."
        )

        begin
          MaxMind::DB.new(path, mode: MaxMind::DB::MODE_MEMORY)
        rescue StandardError => e
          raise ArgumentError, "Failed to open #{option_name} #{path.inspect}: #{e.class}: #{e.message}"
        end
      end

      # Redis-based rotation key (atomic across multiple servers)
      #
      # Uses SET NX GET EX to atomically:
      # 1. Check if key exists
      # 2. Set new key only if missing
      # 3. Return existing or newly set key
      # 4. Auto-expire with TTL
      #
      # @return [String] Current rotation key
      # @api private
      def rotation_key_redis
        now_seconds = Time.now.utc.to_i

        # Quantize to rotation period boundary
        rotation_timestamp = (now_seconds / @hash_rotation_period) * @hash_rotation_period

        redis_key = "rotation_key:#{rotation_timestamp}"
        ttl = (@hash_rotation_period * 1.2).to_i # Auto-cleanup with 20% buffer

        key = SecureRandom.hex(32)

        # SET NX GET returns old value if key exists, nil if we set it
        # @see https://valkey.io/commands/set/
        existing_key = @redis.set(redis_key, key, nx: true, get: true, ex: ttl)

        existing_key || key
      end

      # In-memory rotation key (single-server fallback)
      #
      # Uses class-level Concurrent::Hash for thread-safety within a single process.
      # NOT atomic across multiple servers.
      #
      # The rotation keys are stored at the class level so they remain mutable
      # even when config instances are frozen.
      #
      # @return [String] Current rotation key
      # @api private
      def rotation_key_memory
        rotation_keys = self.class.rotation_keys_store

        now_seconds = Time.now.utc.to_i

        # Quantize to rotation period boundary (e.g., midnight UTC for 24-hour period)
        seconds_since_epoch = now_seconds % @hash_rotation_period
        rotation_timestamp = now_seconds - seconds_since_epoch

        # Atomically get or create key for this rotation period
        # Use compute_if_absent for thread-safe atomic operation
        key = rotation_keys.compute_if_absent(rotation_timestamp) do
          # Generate new key atomically
          # IMPORTANT: Don't modify the map inside this block to avoid deadlock
          SecureRandom.hex(32)
        end

        # Clean up old keys after atomic operation completes
        # This runs outside compute_if_absent to avoid deadlock
        if rotation_keys.size > 1
          rotation_keys.each_key do |ts|
            rotation_keys.delete(ts) if ts != rotation_timestamp
          end
        end

        key
      end
    end
    # rubocop:enable Metrics/ClassLength
  end
end
