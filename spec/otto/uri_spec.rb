# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Otto, '#uri' do
  let(:complex_routes) do
    [
      'GET / TestApp.index',
      'GET /show/:id TestApp.show',
      'GET /users/:user_id/posts/:post_id TestApp.user_post',
      'GET /search TestApp.search',
      'PUT /update/:id TestApp.update'
    ]
  end

  let(:routes_file) { create_test_routes_file('uri_test_routes.txt', complex_routes) }
  subject(:otto) { described_class.new(routes_file) }

  describe 'basic URI generation' do
    it 'generates URIs for route definitions' do
      uri = otto.uri('TestApp.index')
      expect(uri).to eq('/')
    end

    it 'returns nil for non-existent route definitions' do
      uri = otto.uri('NonExistent.method')
      expect(uri).to be_nil
    end

    it 'handles routes with single path parameters' do
      uri = otto.uri('TestApp.show', id: '123')
      expect(uri).to eq('/show/123')
    end
  end

  describe 'multiple path parameters' do
    it 'replaces multiple path parameters correctly' do
      uri = otto.uri('TestApp.user_post', user_id: '456', post_id: '789')
      expect(uri).to eq('/users/456/posts/789')
    end

    it 'replaces path parameters in correct order' do
      uri = otto.uri('TestApp.user_post', post_id: 'abc', user_id: 'def')
      expect(uri).to eq('/users/def/posts/abc')
    end

    it 'handles missing path parameters by leaving placeholders' do
      uri = otto.uri('TestApp.user_post', user_id: '123')
      expect(uri).to eq('/users/123/posts/:post_id')
    end
  end

  describe 'query parameter handling' do
    it 'generates query parameters for unused params' do
      uri = otto.uri('TestApp.index', page: '2', sort: 'name')
      expect(uri).to include('page=2')
      expect(uri).to include('sort=name')
      expect(uri).to include('?')
    end

    it 'combines path and query parameters' do
      uri = otto.uri('TestApp.show', id: '123', format: 'json', lang: 'en')
      expect(uri).to start_with('/show/123?')
      expect(uri).to include('format=json')
      expect(uri).to include('lang=en')
    end

    it 'preserves query parameter order consistently' do
      uri1 = otto.uri('TestApp.index', a: '1', b: '2', c: '3')
      uri2 = otto.uri('TestApp.index', a: '1', b: '2', c: '3')
      expect(uri1).to eq(uri2)
    end

    it 'handles empty query parameter values' do
      uri = otto.uri('TestApp.index', empty: '', blank: nil, zero: 0)
      expect(uri).to include('empty=')
      expect(uri).to include('blank=')
      expect(uri).to include('zero=0')
    end
  end

  describe 'URL encoding' do
    it 'properly encodes special characters in query parameters' do
      uri = otto.uri('TestApp.search', q: 'hello world', filter: 'type=user&active=true')
      expect(uri).to include('q=hello+world')  # URI.encode_www_form_component uses + for spaces
      expect(uri).to include('filter=type%3Duser%26active%3Dtrue')
    end

    it 'encodes Unicode characters correctly' do
      uri = otto.uri('TestApp.search', q: 'café naïve résumé')
      expect(uri).to include('q=caf%C3%A9+na%C3%AFve+r%C3%A9sum%C3%A9')  # + for spaces
    end

    it 'encodes parameter names with special characters' do
      uri = otto.uri('TestApp.search', 'search-term' => 'test', 'filter[type]' => 'user')
      expect(uri).to include('search-term=test')
      expect(uri).to include('filter%5Btype%5D=user')
    end

    it 'handles percent characters in values' do
      uri = otto.uri('TestApp.search', discount: '20%', completion: '100%')
      expect(uri).to include('discount=20%25')
      expect(uri).to include('completion=100%25')
    end
  end

  describe 'parameter type handling' do
    it 'converts non-string path parameters to strings' do
      uri = otto.uri('TestApp.show', id: 123)
      expect(uri).to eq('/show/123')
    end

    it 'converts symbol parameters to strings' do
      uri = otto.uri('TestApp.show', id: :test)
      expect(uri).to eq('/show/test')
    end

    it 'handles boolean parameters' do
      uri = otto.uri('TestApp.search', active: true, deleted: false)
      expect(uri).to include('active=true')
      expect(uri).to include('deleted=false')
    end

    it 'handles numeric parameters' do
      uri = otto.uri('TestApp.search', page: 2, limit: 50, price: 19.99)
      expect(uri).to include('page=2')
      expect(uri).to include('limit=50')
      expect(uri).to include('price=19.99')
    end

    it 'handles array parameters' do
      uri = otto.uri('TestApp.search', tags: ['ruby', 'web', 'framework'])
      # Arrays should be converted to strings
      expect(uri).to match(/tags=/)
    end
  end

  describe 'edge cases and error conditions' do
    it 'handles routes with no parameters gracefully' do
      uri = otto.uri('TestApp.index', unexpected: 'param')
      expect(uri).to include('unexpected=param')
    end

    it 'handles empty parameter hash' do
      uri = otto.uri('TestApp.show', {})
      expect(uri).to eq('/show/:id')  # Placeholder remains
    end

    it 'handles parameters with same name as path parameters' do
      # If both path and query have 'id', path takes precedence
      uri = otto.uri('TestApp.show', id: '123', other_id: '456')
      expect(uri).to eq('/show/123?other_id=456')
    end

    it 'preserves original route and params objects' do
      original_params = { id: '123', page: '2' }
      uri = otto.uri('TestApp.show', original_params)

      # Original params should not be modified
      expect(original_params).to eq({ id: '123', page: '2' })
      expect(uri).to eq('/show/123?page=2')
    end
  end

  describe 'performance considerations' do
    it 'handles large numbers of query parameters efficiently' do
      large_params = {}
      (1..100).each { |i| large_params["param#{i}"] = "value#{i}" }

      start_time = Time.now
      uri = otto.uri('TestApp.index', large_params)
      execution_time = Time.now - start_time

      expect(uri).to start_with('/?')
      expect(execution_time).to be < 0.1  # Should complete in under 100ms
    end

    it 'handles complex parameter values efficiently' do
      complex_params = {
        json: '{"key":"value","nested":{"array":[1,2,3]}}',
        xml: '<root><item>value</item></root>',
        query: 'SELECT * FROM users WHERE name LIKE "%test%"'
      }

      uri = otto.uri('TestApp.search', complex_params)
      expect(uri).to include('json=')
      expect(uri).to include('xml=')
      expect(uri).to include('query=')
    end
  end

  describe 'RFC compliance' do
    it 'generates valid URIs according to RFC 3986' do
      uri = otto.uri('TestApp.search', q: 'test query', type: 'exact')

      # Should not contain unencoded spaces or special characters
      expect(uri).not_to include(' ')
      expect(uri).to match(%r{^/[^?]*(\?[^#]*)?$})  # Basic URI structure
    end

    it 'handles reserved characters correctly' do
      reserved_chars = {
        'colon' => 'a:b',
        'slash' => 'a/b',
        'question' => 'a?b',
        'hash' => 'a#b',
        'bracket' => 'a[b]',
        'at' => 'a@b'
      }

      uri = otto.uri('TestApp.search', reserved_chars)

      # All reserved characters should be properly encoded
      expect(uri).to include('colon=a%3Ab')
      expect(uri).to include('slash=a%2Fb')
      expect(uri).to include('question=a%3Fb')
      expect(uri).to include('hash=a%23b')
      expect(uri).to include('bracket=a%5Bb%5D')
      expect(uri).to include('at=a%40b')
    end
  end
end
