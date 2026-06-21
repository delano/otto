# spec/otto/utils_spec.rb
#
# frozen_string_literal: true

require "spec_helper"

RSpec.describe Otto::Utils do
  describe "#now" do
    it "returns current time in UTC" do
      freeze_time = Time.parse("2023-01-01 12:00:00 UTC")
      allow(Time).to receive(:now).and_return(freeze_time)

      result = Otto::Utils.now

      expect(result).to eq(freeze_time.utc)
      expect(result.zone).to eq("UTC")
    end
  end

  describe "#now_in_μs" do
    it "returns current time in microseconds using monotonic clock" do
      expected_time = 1_672_574_400_123_456
      allow(Process).to receive(:clock_gettime)
        .with(Process::CLOCK_MONOTONIC, :microsecond)
        .and_return(expected_time)

      result = Otto::Utils.now_in_μs

      expect(result).to eq(expected_time)
      expect(result).to be_a(Integer)
    end

    it "uses monotonic clock for accurate time measurement" do
      expect(Process).to receive(:clock_gettime)
        .with(Process::CLOCK_MONOTONIC, :microsecond)
        .and_return(123_456_789)

      result = Otto::Utils.now_in_μs
      expect(result).to eq(123_456_789)
    end

    it "returns increasing values for successive calls" do
      first_time = Otto::Utils.now_in_μs
      sleep(0.001)
      second_time = Otto::Utils.now_in_μs

      expect(second_time).to be > first_time
    end

    it "can be used to measure duration accurately" do
      start_time = Otto::Utils.now_in_μs
      sleep(0.01)
      end_time = Otto::Utils.now_in_μs

      duration = end_time - start_time

      expect(duration).to be_between(8_000, 15_000)
    end
  end

  describe "#now_in_microseconds (alias)" do
    it "is an alias for now_in_μs" do
      expect(Otto::Utils.method(:now_in_microseconds)).to eq(Otto::Utils.method(:now_in_μs))
    end

    it "returns the same value as now_in_μs" do
      expected_time = 987_654_321
      allow(Process).to receive(:clock_gettime)
        .with(Process::CLOCK_MONOTONIC, :microsecond)
        .and_return(expected_time)

      expect(Otto::Utils.now_in_microseconds).to eq(Otto::Utils.now_in_μs)
      expect(Otto::Utils.now_in_microseconds).to eq(expected_time)
    end
  end

  describe "#yes?" do
    it "returns true for truthy string values" do
      expect(Otto::Utils.yes?("true")).to be true
      expect(Otto::Utils.yes?("TRUE")).to be true
      expect(Otto::Utils.yes?("yes")).to be true
      expect(Otto::Utils.yes?("YES")).to be true
      expect(Otto::Utils.yes?("1")).to be true
    end

    it "returns false for falsy string values" do
      expect(Otto::Utils.yes?("false")).to be false
      expect(Otto::Utils.yes?("no")).to be false
      expect(Otto::Utils.yes?("0")).to be false
      expect(Otto::Utils.yes?("random")).to be false
    end

    it "returns false for empty or nil values" do
      expect(Otto::Utils.yes?(nil)).to be false
      expect(Otto::Utils.yes?("")).to be false
      expect(Otto::Utils.yes?("   ")).to be false
    end

    it "handles non-string values by converting to string" do
      expect(Otto::Utils.yes?(1)).to be true
      expect(Otto::Utils.yes?(0)).to be false
      expect(Otto::Utils.yes?(true)).to be true
      expect(Otto::Utils.yes?(false)).to be false
    end
  end

  describe "#normalize_ip" do
    it "accepts a bare IPv4 address" do
      expect(Otto::Utils.normalize_ip("203.0.113.5")).to eq("203.0.113.5")
    end

    it "accepts a bare IPv6 address without truncating it" do
      expect(Otto::Utils.normalize_ip("2001:db8::1")).to eq("2001:db8::1")
    end

    it "strips a port from an IPv4 host:port" do
      expect(Otto::Utils.normalize_ip("203.0.113.5:8080")).to eq("203.0.113.5")
    end

    it "strips a port from a bracketed IPv6 address" do
      expect(Otto::Utils.normalize_ip("[2001:db8::1]:443")).to eq("2001:db8::1")
    end

    it "trims surrounding whitespace" do
      expect(Otto::Utils.normalize_ip("  203.0.113.5  ")).to eq("203.0.113.5")
    end

    it "returns nil for malformed or blank input" do
      expect(Otto::Utils.normalize_ip("nope")).to be_nil
      expect(Otto::Utils.normalize_ip("")).to be_nil
      expect(Otto::Utils.normalize_ip(nil)).to be_nil
    end
  end

  describe "#strip_ip_port" do
    it "removes a port from an IPv4 host:port" do
      expect(Otto::Utils.strip_ip_port("203.0.113.5:8080")).to eq("203.0.113.5")
    end

    it "unwraps a bracketed IPv6 literal with a port" do
      expect(Otto::Utils.strip_ip_port("[2001:db8::1]:443")).to eq("2001:db8::1")
    end

    it "leaves a bare IPv6 address unchanged" do
      expect(Otto::Utils.strip_ip_port("2001:db8::1")).to eq("2001:db8::1")
    end

    it "leaves a bare IPv4 address unchanged" do
      expect(Otto::Utils.strip_ip_port("203.0.113.5")).to eq("203.0.113.5")
    end
  end

  describe "#private_ip?" do
    it "recognizes IPv4 RFC1918 private ranges" do
      expect(Otto::Utils.private_ip?("10.1.2.3")).to be true
      expect(Otto::Utils.private_ip?("172.16.0.1")).to be true
      expect(Otto::Utils.private_ip?("172.31.255.255")).to be true
      expect(Otto::Utils.private_ip?("192.168.1.1")).to be true
    end

    it "does not treat 172.32.x as private (boundary)" do
      expect(Otto::Utils.private_ip?("172.32.0.1")).to be false
      expect(Otto::Utils.private_ip?("172.15.255.255")).to be false
    end

    it "recognizes IPv4 loopback, link-local, multicast and unspecified" do
      expect(Otto::Utils.private_ip?("127.0.0.1")).to be true
      expect(Otto::Utils.private_ip?("169.254.1.1")).to be true # link-local
      expect(Otto::Utils.private_ip?("224.0.0.1")).to be true   # multicast
      expect(Otto::Utils.private_ip?("239.255.255.255")).to be true # multicast (/4)
      expect(Otto::Utils.private_ip?("0.0.0.0")).to be true
    end

    it "treats public IPv4 as non-private" do
      expect(Otto::Utils.private_ip?("8.8.8.8")).to be false
      expect(Otto::Utils.private_ip?("203.0.113.5")).to be false
    end

    it "recognizes IPv6 loopback, ULA, link-local, multicast and unspecified" do
      expect(Otto::Utils.private_ip?("::1")).to be true             # loopback
      expect(Otto::Utils.private_ip?("fc00::1")).to be true         # ULA
      expect(Otto::Utils.private_ip?("fd12:3456:789a::1")).to be true # ULA
      expect(Otto::Utils.private_ip?("fe80::1")).to be true         # link-local
      expect(Otto::Utils.private_ip?("ff02::1")).to be true         # multicast
      expect(Otto::Utils.private_ip?("::")).to be true              # unspecified
    end

    it "treats public IPv6 as non-private" do
      expect(Otto::Utils.private_ip?("2606:4700:4700::1111")).to be false
      expect(Otto::Utils.private_ip?("2001:4860:4860::8888")).to be false
    end

    it "folds IPv4-mapped IPv6 to its IPv4 classification" do
      expect(Otto::Utils.private_ip?("::ffff:10.0.0.1")).to be true
      expect(Otto::Utils.private_ip?("::ffff:8.8.8.8")).to be false
    end

    it "accepts an IPAddr object directly" do
      expect(Otto::Utils.private_ip?(IPAddr.new("10.0.0.1"))).to be true
      expect(Otto::Utils.private_ip?(IPAddr.new("8.8.8.8"))).to be false
    end

    it "returns false for nil, empty or malformed input instead of raising" do
      expect(Otto::Utils.private_ip?(nil)).to be false
      expect(Otto::Utils.private_ip?("")).to be false
      expect(Otto::Utils.private_ip?("not-an-ip")).to be false
    end
  end

  describe "#resolve_client_ip" do
    def config_with(*proxies)
      cfg = Otto::Security::Config.new
      proxies.each { |p| cfg.add_trusted_proxy(p) }
      cfg
    end

    it "returns REMOTE_ADDR when there is no security config" do
      env = { "REMOTE_ADDR" => "203.0.113.5", "HTTP_X_FORWARDED_FOR" => "1.2.3.4" }
      expect(Otto::Utils.resolve_client_ip(env, nil)).to eq("203.0.113.5")
    end

    it "returns REMOTE_ADDR when the peer is not a trusted proxy" do
      env = { "REMOTE_ADDR" => "198.51.100.9", "HTTP_X_FORWARDED_FOR" => "1.2.3.4" }
      expect(Otto::Utils.resolve_client_ip(env, config_with("10.0.0.0/8"))).to eq("198.51.100.9")
    end

    it "resolves the forwarded client when the peer is a trusted proxy" do
      env = { "REMOTE_ADDR" => "10.0.0.1", "HTTP_X_FORWARDED_FOR" => "203.0.113.50" }
      expect(Otto::Utils.resolve_client_ip(env, config_with("10.0.0.0/8"))).to eq("203.0.113.50")
    end

    it "walks the forwarded chain and returns the first non-proxy address" do
      env = {
        "REMOTE_ADDR" => "10.0.0.1",
        "HTTP_X_FORWARDED_FOR" => "203.0.113.50, 10.0.0.9, 10.0.0.1",
      }
      expect(Otto::Utils.resolve_client_ip(env, config_with("10.0.0.0/8"))).to eq("203.0.113.50")
    end

    it "honors X-Real-IP and X-Client-IP in addition to X-Forwarded-For" do
      real = { "REMOTE_ADDR" => "10.0.0.1", "HTTP_X_REAL_IP" => "203.0.113.7" }
      client = { "REMOTE_ADDR" => "10.0.0.1", "HTTP_X_CLIENT_IP" => "203.0.113.8" }
      cfg = config_with("10.0.0.0/8")

      expect(Otto::Utils.resolve_client_ip(real, cfg)).to eq("203.0.113.7")
      expect(Otto::Utils.resolve_client_ip(client, cfg)).to eq("203.0.113.8")
    end

    it "falls back to REMOTE_ADDR when the whole chain is trusted proxies" do
      env = { "REMOTE_ADDR" => "10.0.0.1", "HTTP_X_FORWARDED_FOR" => "10.0.0.9, 10.0.0.8" }
      expect(Otto::Utils.resolve_client_ip(env, config_with("10.0.0.0/8"))).to eq("10.0.0.1")
    end

    it "resolves IPv6 clients behind an IPv6 trusted proxy without truncation" do
      env = { "REMOTE_ADDR" => "2001:db8::1", "HTTP_X_FORWARDED_FOR" => "2606:4700:4700::1111" }
      expect(Otto::Utils.resolve_client_ip(env, config_with("2001:db8::/32"))).to eq("2606:4700:4700::1111")
    end
  end
end
