# lib/otto/mcp/request_state.rb
#
# frozen_string_literal: true

require 'json'
require 'openssl'

require_relative 'errors'

class Otto
  module MCP
    # Seals and opens the +requestState+ a tool sends with an input request.
    #
    # The client returns +requestState+ unchanged when it retries the call,
    # which makes it input from the caller. Otto encrypts and authenticates
    # it with AES-256-GCM and binds it to the caller, the method, the tool
    # name and the tool arguments, so a state issued to one caller for one
    # call opens only for that caller repeating that call. It also expires.
    #
    # A sealed state can be presented more than once until it expires. A
    # handler that must act once per state enforces that itself.
    class RequestState
      PREFIX = 'v1.'

      # Largest sealed value accepted, in bytes, before any decoding.
      MAX_BYTES = 16_384

      IV_BYTES  = 12
      TAG_BYTES = 16

      # @param secret [String] at least 32 bytes
      # @param on_first_seal [#call, nil] called before the first state is
      #   sealed
      def initialize(secret, on_first_seal: nil)
        @key = OpenSSL::KDF.hkdf(secret.to_s, salt: 'otto.mcp.request_state', info: 'aes-256-gcm v1',
                                 length: 32, hash: 'SHA256').freeze
        @on_first_seal = on_first_seal
      end

      # @return [String] class name only; the key is never printed
      def inspect
        "#<#{self.class.name}>"
      end

      # @param data [Hash] JSON-serializable values for the handler
      # @param binding [String] identifies the caller and the call
      # @param ttl [Integer] seconds until the state expires
      # @param now [Time]
      # @return [String] the opaque value sent as +requestState+
      def seal(data, binding:, ttl:, now: Time.now)
        announce_first_seal

        cipher = OpenSSL::Cipher.new('aes-256-gcm').encrypt
        cipher.key       = @key
        iv               = cipher.random_iv
        cipher.auth_data = binding
        ciphertext       = cipher.update(JSON.generate({ 'e' => now.to_i + ttl, 'd' => data })) + cipher.final

        PREFIX + encode(iv + cipher.auth_tag + ciphertext)
      end

      # @param sealed [String] the +requestState+ a client sent back
      # @param binding [String] identifies the caller and the call now being made
      # @param now [Time]
      # @return [Hash] the data given to {#seal}
      # @raise [Otto::MCP::InvalidRequestStateError] if the value is malformed,
      #   altered, expired, or bound to another caller or call
      def open(sealed, binding:, now: Time.now)
        raise InvalidRequestStateError, 'malformed' unless well_formed?(sealed)

        encoded = sealed.delete_prefix(PREFIX)
        raise InvalidRequestStateError, 'malformed' unless encoded.match?(/\A[A-Za-z0-9_-]+\z/)

        raw = encoded.tr('-_', '+/').unpack1('m')
        raise InvalidRequestStateError, 'malformed' if raw.bytesize <= IV_BYTES + TAG_BYTES
        # One state has one spelling: stray bits in the last character are
        # refused even though they decode to the same bytes.
        raise InvalidRequestStateError, 'malformed' unless encode(raw) == encoded

        payload = JSON.parse(decrypt(raw, binding))
        raise InvalidRequestStateError, 'expired' unless payload['e'].is_a?(Integer) && payload['e'] > now.to_i

        payload['d']
      rescue OpenSSL::Cipher::CipherError, JSON::ParserError
        raise InvalidRequestStateError, 'rejected'
      end

      private

      # Two requests arriving together may both announce. Nothing depends on
      # the hook running exactly once.
      def announce_first_seal
        hook           = @on_first_seal
        @on_first_seal = nil
        hook&.call
      end

      def encode(bytes)
        [bytes].pack('m0').tr('+/', '-_').delete('=')
      end

      def well_formed?(sealed)
        sealed.is_a?(String) && sealed.bytesize <= MAX_BYTES && sealed.start_with?(PREFIX)
      end

      def decrypt(raw, binding)
        cipher           = OpenSSL::Cipher.new('aes-256-gcm').decrypt
        cipher.key       = @key
        cipher.iv        = raw.byteslice(0, IV_BYTES)
        cipher.auth_tag  = raw.byteslice(IV_BYTES, TAG_BYTES)
        cipher.auth_data = binding
        cipher.update(raw.byteslice((IV_BYTES + TAG_BYTES)..)) + cipher.final
      end
    end
  end
end
