# lib/otto/mcp/call.rb
#
# frozen_string_literal: true

require 'json'
require 'uri'

class Otto
  module MCP
    # What Otto knows about one +tools/call+ or +resources/read+, for the
    # handler. Otto stores it in +env['otto.mcp.call']+ before the handler runs.
    #
    # +auth+ and +state+ are verified by Otto. +client_capabilities+,
    # +client_info+ and +input_responses+ are what the client sent and prove
    # nothing about who sent them.
    Call = Data.define(:auth, :protocol_version, :client_capabilities, :client_info, :input_responses, :state) do
      # @param auth [Otto::MCP::Auth::Context, nil] the verified caller
      # @param protocol_version [String] revision the request is served under
      # @param client_capabilities [Hash] capabilities declared on this request
      # @param client_info [Hash, nil] name and version the client reports
      # @param input_responses [Hash] the client's answers to input requests
      # @param state [Hash, nil] the state given to {InputRequired.url} when
      #   this call is the retry of that input request, nil on a first call
      def initialize(protocol_version:, auth: nil, client_capabilities: {}, client_info: nil, input_responses: {}, state: nil)
        super
      end

      # @return [Boolean] true when the client declared that it can open a
      #   URL for the person using it
      def url_elicitation?
        elicitation = client_capabilities['elicitation']
        elicitation.is_a?(Hash) && elicitation['url'].is_a?(Hash)
      end

      # @return [Boolean] true when this call retries an input request this
      #   endpoint issued to the same caller for the same arguments
      def retry?
        !state.nil?
      end

      # What the client reports the person did with an input request:
      # +"accept"+, +"decline"+ or +"cancel"+.
      #
      # For a URL request, +"accept"+ means the person agreed to open the
      # page. It does not mean they finished what the page asks for. Only the
      # application that serves the page knows that.
      #
      # @param key [String] the key given to {InputRequired.url}
      # @return [String, nil]
      def input_action(key)
        response = input_responses[key]
        response['action'] if response.is_a?(Hash) && response['action'].is_a?(String)
      end
    end

    # Returned by a tool handler that needs the person at the MCP client to do
    # something first. Otto answers the call with an input request, and the
    # client retries the call when the person has responded.
    #
    # @example Send the person to a page to enter a value
    #   Otto::MCP::InputRequired.url(
    #     'handoff',
    #     url: 'https://example.com/handoffs/pending',
    #     message: 'Enter the secret on example.com.',
    #     state: { 'operation_id' => operation.id },
    #   )
    InputRequired = Data.define(:requests, :state, :ttl) do
      # Ask the client to open a page in the person's browser.
      #
      # Use this for anything sensitive: the value the person enters goes to
      # the page and never passes through the client or the model. The URL
      # must not carry a credential, personal data, or anything that signs
      # the person in. The page must check, from its own browser session,
      # that the person who opened it is the caller the request was issued
      # to.
      #
      # @param key [String] names this request in the client's response
      # @param url [String] absolute http or https URL
      # @param message [String] tells the person why the page is needed
      # @param state [Hash, nil] JSON values returned to the handler as
      #   {Call#state} on the retry. Otto encrypts it and binds it to the
      #   caller and the call. At most MAX_STATE_BYTES of JSON: keep the
      #   record in your own store and put its identifier here.
      # @param ttl [Integer] seconds the state stays valid
      # @return [Otto::MCP::InputRequired]
      # @raise [ArgumentError] for an invalid key, URL, message, state or ttl
      def self.url(key, url:, message:, state: nil, ttl: self::DEFAULT_TTL)
        raise ArgumentError, 'MCP input request key must be a non-blank String' unless text?(key)
        raise ArgumentError, 'MCP input request message must be a non-blank String' unless text?(message)
        raise ArgumentError, 'MCP input request url must be an absolute http or https URL' unless http_url?(url)
        raise ArgumentError, 'MCP input request state must be a Hash or nil' unless state.nil? || state.is_a?(Hash)

        fits = state.nil? || JSON.generate(state).bytesize <= self::MAX_STATE_BYTES
        raise ArgumentError, "MCP input request state must be at most #{self::MAX_STATE_BYTES} bytes of JSON" unless fits

        in_range = ttl.is_a?(Integer) && ttl.between?(1, self::MAX_TTL)
        raise ArgumentError, "MCP input request ttl must be 1 to #{self::MAX_TTL} seconds" unless in_range

        request = { 'method' => 'elicitation/create', 'params' => { 'mode' => 'url', 'url' => url, 'message' => message } }
        new(requests: { key => request }.freeze, state: state || {}, ttl: ttl)
      end

      # @api private
      def self.text?(value)
        value.is_a?(String) && !value.strip.empty?
      end
      private_class_method :text?

      # @api private
      def self.http_url?(url)
        return false unless url.is_a?(String)

        uri = URI.parse(url)
        uri.is_a?(URI::HTTP) && !uri.host.to_s.empty?
      rescue URI::InvalidURIError
        false
      end
      private_class_method :http_url?

      # @return [Hash] the client capability every request in this answer needs
      def required_capabilities
        { 'elicitation' => { 'url' => {} } }
      end
    end

    # Seconds an input request's state stays valid unless +ttl:+ says otherwise.
    InputRequired::DEFAULT_TTL = 900

    # Longest +ttl:+ accepted.
    InputRequired::MAX_TTL = 86_400

    # Largest +state:+ accepted, as JSON. A sealed state of this size is
    # within what {Otto::MCP::RequestState} accepts back.
    InputRequired::MAX_STATE_BYTES = 8192
  end
end
