# frozen_string_literal: true

require 'spec_helper'
require 'net/http'
require 'uri'
require 'yaml'

RSpec.describe 'Comprehensive User Agent Anonymization' do
  let(:app) { ->(env) { [200, {}, ['OK']] } }
  let(:security_config) { Otto::Security::Config.new }
  let(:middleware) { Otto::Security::Middleware::IPPrivacyMiddleware.new(app, security_config) }

  # Fetch real user agent test data from uap-core repository
  def fetch_uap_core_test_data
    url = 'https://raw.githubusercontent.com/ua-parser/uap-core/master/tests/test_ua.yaml'
    uri = URI.parse(url)
    response = Net::HTTP.get_response(uri)

    return nil unless response.is_a?(Net::HTTPSuccess)

    YAML.safe_load(response.body, permitted_classes: [Symbol], aliases: true)
  rescue StandardError => e
    warn "Failed to fetch uap-core test data: #{e.message}"
    nil
  end

  # Fallback: Comprehensive list of real user agents from various sources
  # Including Android devices with build numbers, iOS devices, desktop browsers, etc.
  def fallback_user_agents
    [
      # Android devices with various build number formats
      'Mozilla/5.0 (Linux; U; Android 2.2.2; en-gb; HTC Desire Build/FRG83G) AppleWebKit/533.1 (KHTML, like Gecko) Version/4.0 Mobile Safari/533.1',
      'Mozilla/5.0 (Linux; U; Android 4.0.3; en-us; KFTT Build/IML74K) AppleWebKit/534.30 (KHTML, like Gecko) Silk/2.1 Mobile Safari/534.30',
      'Mozilla/5.0 (Linux; Android 6.0.1; Moto G (4) Build/MPJ24.139-64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/51.0.2704.81 Mobile Safari/537.36',
      'Mozilla/5.0 (Linux; Android 5.0; Nexus 5 Build/MRA58N) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Mobile Safari/537.36',
      'Mozilla/5.0 (Linux; Android 7.0; Pixel Build/NRD90M) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/57.0.2987.132 Mobile Safari/537.36',
      'Mozilla/5.0 (Linux; Android 8.0.0; Pixel 2 Build/OPD1.170816.004) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/63.0.3239.111 Mobile Safari/537.36',
      'Mozilla/5.0 (Linux; Android 9; Pixel 3 Build/PD1A.180720.030) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/69.0.3497.100 Mobile Safari/537.36',
      'Mozilla/5.0 (Linux; Android 10; Pixel 4 Build/QD1A.190821.014.C2) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/78.0.3904.108 Mobile Safari/537.36',
      'Mozilla/5.0 (Linux; Android 11; Pixel 5 Build/RD1A.200810.022.A4) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/85.0.4183.127 Mobile Safari/537.36',
      'Mozilla/5.0 (Linux; Android 4.4.2; SM-T530NU Build/KOT49H) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/45.0.2454.84 Safari/537.36',

      # iOS devices (various versions)
      'Mozilla/5.0 (iPhone; CPU iPhone OS 12_4 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/12.1.2 Mobile/15E148 Safari/604.1',
      'Mozilla/5.0 (iPhone; CPU iPhone OS 13_5_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/13.1.1 Mobile/15E148 Safari/604.1',
      'Mozilla/5.0 (iPhone; CPU iPhone OS 14_7_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/14.1.2 Mobile/15E148 Safari/604.1',
      'Mozilla/5.0 (iPhone; CPU iPhone OS 15_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/15.6 Mobile/15E148 Safari/604.1',
      'Mozilla/5.0 (iPad; CPU OS 3_2 like Mac OS X; en-us) AppleWebKit/531.21.10 (KHTML, like Gecko) Version/4.0.4 Mobile/7B367 Safari/531.21.10',
      'Mozilla/5.0 (iPad; CPU OS 11_4 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/11.0 Mobile/15E148 Safari/604.1',
      'Mozilla/5.0 (iPod; U; CPU iPhone OS 4_3_2 like Mac OS X; en-us) AppleWebKit/533.17.9 (KHTML, like Gecko) Version/5.0.2 Mobile/8H7 Safari/6533.18.5',

      # macOS browsers
      'Mozilla/5.0 (Macintosh; U; Intel Mac OS X 10_6_5; en-us) AppleWebKit/533.18.1 (KHTML, like Gecko) Version/5.0.2 Safari/533.18.5',
      'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_14_6) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/78.0.3904.97 Safari/537.36',
      'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.124 Safari/537.36',
      'Mozilla/5.0 (Macintosh; Intel Mac OS X 10.15; rv:89.0) Gecko/20100101 Firefox/89.0',

      # Windows browsers
      'Mozilla/5.0 (Windows NT 6.1; WOW64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/28.0.1500.95 Safari/537.36',
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/96.0.4664.110 Safari/537.36',
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:95.0) Gecko/20100101 Firefox/95.0',
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/96.0.4664.93 Safari/537.36 Edg/96.0.1054.53',

      # Linux browsers
      'Mozilla/5.0 (X11; Linux x86_64; rv:2.0) Gecko/20110408 conkeror/0.9.3',
      'Mozilla/5.0 (X11; Ubuntu; Linux x86_64; rv:89.0) Gecko/20100101 Firefox/89.0',
      'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/92.0.4515.107 Safari/537.36',

      # Edge cases: bots, crawlers, etc.
      'Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)',
      'facebookexternalhit/1.1 (+http://www.facebook.com/externalhit_uatext.php)',
      'Mozilla/5.0 (compatible; bingbot/2.0; +http://www.bing.com/bingbot.htm)'
    ]
  end

  describe 'Testing against real-world user agents' do
    before(:all) do
      @test_data = fetch_uap_core_test_data
      @user_agents = if @test_data && @test_data['test_cases']
                       @test_data['test_cases'].map { |tc| tc['user_agent_string'] }.compact
                     else
                       fallback_user_agents
                     end

      puts "\n" + "=" * 80
      puts "Testing #{@user_agents.size} real user agents from #{@test_data ? 'uap-core repository' : 'fallback list'}"
      puts "=" * 80
    end

    it 'anonymizes all test user agents without errors' do
      failures = []

      @user_agents.each do |ua|
        env = {
          'REMOTE_ADDR' => '9.9.9.9',
          'HTTP_USER_AGENT' => ua
        }

        begin
          middleware.call(env)

          # Verify anonymization occurred
          expect(env['HTTP_USER_AGENT']).not_to be_nil

          # Record if anonymization seems to have failed (no wildcards added for non-trivial UAs)
          if ua.match?(/\d+\.\d+/) && !env['HTTP_USER_AGENT'].include?('*')
            failures << {
              original: ua,
              anonymized: env['HTTP_USER_AGENT'],
              reason: 'Contains version numbers but no wildcards added'
            }
          end
        rescue StandardError => e
          failures << {
            original: ua,
            error: e.message,
            reason: 'Exception during anonymization'
          }
        end
      end

      unless failures.empty?
        puts "\n" + "!" * 80
        puts "Found #{failures.size} potential issues:"
        failures.first(10).each do |f|
          puts "\nOriginal:    #{f[:original]}"
          puts "Anonymized:  #{f[:anonymized]}" if f[:anonymized]
          puts "Error:       #{f[:error]}" if f[:error]
          puts "Reason:      #{f[:reason]}"
        end
        puts "!" * 80
      end

      expect(failures).to be_empty, "Failed to anonymize #{failures.size} user agents (showing first 10 above)"
    end

    it 'removes all Android build identifiers' do
      android_uas = @user_agents.select { |ua| ua.include?('Build/') }

      puts "\nTesting #{android_uas.size} user agents with Build/ identifiers"

      android_uas.each do |ua|
        env = {
          'REMOTE_ADDR' => '9.9.9.9',
          'HTTP_USER_AGENT' => ua
        }
        middleware.call(env)

        # Extract the build ID from original
        build_match = ua.match(/Build\/([\w.-]+)/)
        next unless build_match

        build_id = build_match[1]

        # Verify build ID was replaced
        expect(env['HTTP_USER_AGENT']).to include('Build/*'),
          "Expected Build/* but got: #{env['HTTP_USER_AGENT']}"
        expect(env['HTTP_USER_AGENT']).not_to include("Build/#{build_id}"),
          "Build ID #{build_id} not removed from: #{env['HTTP_USER_AGENT']}"
      end
    end

    it 'removes all version number patterns (X.Y, X.Y.Z, X.Y.Z.W)' do
      # Test UAs that definitely have version numbers
      versioned_uas = @user_agents.select { |ua| ua.match?(/\d+\.\d+/) }

      puts "\nTesting #{versioned_uas.size} user agents with version numbers"

      # Sample check on a subset (to avoid slow tests)
      versioned_uas.sample(50).each do |ua|
        env = {
          'REMOTE_ADDR' => '9.9.9.9',
          'HTTP_USER_AGENT' => ua
        }
        middleware.call(env)

        anonymized = env['HTTP_USER_AGENT']

        # Extract specific version patterns from original
        original_versions = ua.scan(/\d+\.\d+(?:\.\d+)?(?:\.\d+)?/)

        # Check that specific versions are replaced
        original_versions.each do |version|
          # Allow single digits to remain (like "Android 9" or "iOS 12")
          next if version.count('.').zero?

          expect(anonymized).not_to include(version),
            "Version #{version} not removed. Original: #{ua}\nAnonymized: #{anonymized}"
        end
      end
    end

    it 'preserves non-sensitive browser/OS family information' do
      test_cases = [
        { original: 'Mozilla/5.0 (iPhone; CPU iPhone OS 12_4 like Mac OS X)', preserve: ['iPhone', 'Mac OS X'] },
        { original: 'Mozilla/5.0 (Linux; Android 9; Pixel 3)', preserve: ['Linux', 'Android', 'Pixel'] },
        { original: 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/96.0', preserve: ['Windows', 'Win64', 'Chrome'] },
        { original: 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) Safari/605.1', preserve: ['Macintosh', 'Safari'] }
      ]

      test_cases.each do |tc|
        env = {
          'REMOTE_ADDR' => '9.9.9.9',
          'HTTP_USER_AGENT' => tc[:original]
        }
        middleware.call(env)

        anonymized = env['HTTP_USER_AGENT']

        tc[:preserve].each do |text|
          expect(anonymized).to include(text),
            "Expected to preserve '#{text}' in anonymized UA: #{anonymized}"
        end
      end
    end

    it 'produces consistent anonymization (idempotent)' do
      sample_ua = 'Mozilla/5.0 (Linux; Android 10; Pixel 4 Build/QD1A.190821.014) Chrome/78.0.3904.108'

      # Run anonymization twice
      env1 = {
        'REMOTE_ADDR' => '9.9.9.9',
        'HTTP_USER_AGENT' => sample_ua
      }
      middleware.call(env1)
      first_result = env1['HTTP_USER_AGENT']

      # Run on already-anonymized version
      env2 = {
        'REMOTE_ADDR' => '9.9.9.9',
        'HTTP_USER_AGENT' => first_result
      }
      middleware.call(env2)
      second_result = env2['HTTP_USER_AGENT']

      expect(first_result).to eq(second_result),
        "Anonymization should be idempotent. First: #{first_result}, Second: #{second_result}"
    end
  end

  describe 'Pattern coverage verification' do
    it 'handles version numbers with underscores (macOS/iOS style)' do
      uas_with_underscores = [
        'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)',
        'Mozilla/5.0 (iPhone; CPU iPhone OS 14_7_1 like Mac OS X)'
      ]

      uas_with_underscores.each do |ua|
        env = {
          'REMOTE_ADDR' => '9.9.9.9',
          'HTTP_USER_AGENT' => ua
        }
        middleware.call(env)

        # Should replace underscore-separated versions
        expect(env['HTTP_USER_AGENT']).not_to include('10_15_7')
        expect(env['HTTP_USER_AGENT']).not_to include('14_7_1')
        expect(env['HTTP_USER_AGENT']).to include('*')
      end
    end

    it 'handles complex build IDs with dots, hyphens, and underscores' do
      complex_builds = [
        'Build/MPJ24.139-64',
        'Build/QD1A.190821.014.C2',
        'Build/RD1A.200810.022.A4',
        'Build/OPD1.170816.004'
      ]

      complex_builds.each do |build|
        env = {
          'REMOTE_ADDR' => '9.9.9.9',
          'HTTP_USER_AGENT' => "Mozilla/5.0 (Linux; Android 10; Device #{build}) Chrome/80.0"
        }
        middleware.call(env)

        expect(env['HTTP_USER_AGENT']).to include('Build/*')
        expect(env['HTTP_USER_AGENT']).not_to include(build)
      end
    end

    it 'handles multiple build numbers in one UA string' do
      ua = 'CustomBrowser/1.0 Build/ABC123 (Linux; Build/XYZ789) Chrome/100.0.0.0 Build/FOO999'
      env = {
        'REMOTE_ADDR' => '9.9.9.9',
        'HTTP_USER_AGENT' => ua
      }
      middleware.call(env)

      # All build numbers should be replaced
      expect(env['HTTP_USER_AGENT']).not_to include('Build/ABC123')
      expect(env['HTTP_USER_AGENT']).not_to include('Build/XYZ789')
      expect(env['HTTP_USER_AGENT']).not_to include('Build/FOO999')

      # Should have multiple Build/* markers
      expect(env['HTTP_USER_AGENT'].scan(/Build\/\*/).size).to eq(3)
    end
  end
end
