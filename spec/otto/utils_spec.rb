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

  describe "#resolve_client_ip in trusted_proxy_depth mode" do
    def depth_config(depth)
      cfg = Otto::Security::Config.new
      cfg.trusted_proxy_depth = depth
      cfg
    end

    it "trusts one hop: client is the entry left of REMOTE_ADDR (depth 1)" do
      env = { "REMOTE_ADDR" => "10.0.0.1", "HTTP_X_FORWARDED_FOR" => "203.0.113.50" }
      expect(Otto::Utils.resolve_client_ip(env, depth_config(1))).to eq("203.0.113.50")
    end

    it "trusts two hops through an intermediate proxy (depth 2)" do
      env = {
        "REMOTE_ADDR" => "10.0.0.1",                              # nearest proxy (peer)
        "HTTP_X_FORWARDED_FOR" => "203.0.113.50, 10.0.0.9",       # client, intermediate proxy
      }
      expect(Otto::Utils.resolve_client_ip(env, depth_config(2))).to eq("203.0.113.50")
    end

    it "ignores a forged leftmost X-Forwarded-For entry (padding-robust)" do
      # Attacker pads XFF with 9.9.9.9; the proxy appends the real client to the
      # right. With depth 1 only the rightmost hop before REMOTE_ADDR is trusted.
      env = {
        "REMOTE_ADDR" => "10.0.0.1",
        "HTTP_X_FORWARDED_FOR" => "9.9.9.9, 203.0.113.50",
      }
      expect(Otto::Utils.resolve_client_ip(env, depth_config(1))).to eq("203.0.113.50")
    end

    it "is not shifted by invalid padding entries (raw position counting)" do
      env = {
        "REMOTE_ADDR" => "10.0.0.1",
        "HTTP_X_FORWARDED_FOR" => "garbage, , 203.0.113.50",
      }
      expect(Otto::Utils.resolve_client_ip(env, depth_config(1))).to eq("203.0.113.50")
    end

    it "falls back to REMOTE_ADDR when the chain is shorter than depth + 1" do
      # depth 2 needs client + 1 intermediate + peer = 3 positions; only 2 here.
      env = { "REMOTE_ADDR" => "10.0.0.1", "HTTP_X_FORWARDED_FOR" => "203.0.113.50" }
      expect(Otto::Utils.resolve_client_ip(env, depth_config(2))).to eq("10.0.0.1")
    end

    it "falls back to REMOTE_ADDR when there is no X-Forwarded-For header" do
      env = { "REMOTE_ADDR" => "10.0.0.1" }
      expect(Otto::Utils.resolve_client_ip(env, depth_config(1))).to eq("10.0.0.1")
    end

    it "falls back to REMOTE_ADDR when the target entry is not a valid IP" do
      env = { "REMOTE_ADDR" => "10.0.0.1", "HTTP_X_FORWARDED_FOR" => "not-an-ip" }
      expect(Otto::Utils.resolve_client_ip(env, depth_config(1))).to eq("10.0.0.1")
    end

    it "resolves an IPv6 client without truncation under depth" do
      env = { "REMOTE_ADDR" => "2001:db8::1", "HTTP_X_FORWARDED_FOR" => "2606:4700:4700::1111" }
      expect(Otto::Utils.resolve_client_ip(env, depth_config(1))).to eq("2606:4700:4700::1111")
    end

    it "ignores X-Real-IP / X-Client-IP in depth mode (X-Forwarded-For only)" do
      env = {
        "REMOTE_ADDR" => "10.0.0.1",
        "HTTP_X_FORWARDED_FOR" => "203.0.113.50",
        "HTTP_X_REAL_IP" => "9.9.9.9",
        "HTTP_X_CLIENT_IP" => "8.8.8.8",
      }
      expect(Otto::Utils.resolve_client_ip(env, depth_config(1))).to eq("203.0.113.50")
    end

    it "leaves CIDR-walk untouched when depth is nil (regression)" do
      cfg = Otto::Security::Config.new
      cfg.add_trusted_proxy("10.0.0.0/8")
      env = { "REMOTE_ADDR" => "10.0.0.1", "HTTP_X_FORWARDED_FOR" => "203.0.113.50" }
      expect(Otto::Utils.resolve_client_ip(env, cfg)).to eq("203.0.113.50")
    end

    it "leaves CIDR-walk untouched when depth is 0 (regression)" do
      cfg = Otto::Security::Config.new
      cfg.trusted_proxy_depth = 0
      cfg.add_trusted_proxy("10.0.0.0/8")
      env = { "REMOTE_ADDR" => "10.0.0.1", "HTTP_X_FORWARDED_FOR" => "203.0.113.50" }
      expect(Otto::Utils.resolve_client_ip(env, cfg)).to eq("203.0.113.50")
    end
  end

  describe "#resolve_client_ip in depth mode with a configurable header" do
    def depth_config(depth, header)
      cfg = Otto::Security::Config.new
      cfg.trusted_proxy_depth = depth
      cfg.trusted_proxy_header = header
      cfg
    end

    context "header = 'Forwarded' (RFC 7239)" do
      it "resolves the for= entry one hop from the right (depth 1)" do
        env = { "REMOTE_ADDR" => "10.0.0.1", "HTTP_FORWARDED" => "for=203.0.113.50" }
        expect(Otto::Utils.resolve_client_ip(env, depth_config(1, "Forwarded"))).to eq("203.0.113.50")
      end

      it "trusts two hops through an intermediate proxy (depth 2)" do
        env = {
          "REMOTE_ADDR" => "10.0.0.1",
          "HTTP_FORWARDED" => "for=203.0.113.50, for=10.0.0.9",
        }
        expect(Otto::Utils.resolve_client_ip(env, depth_config(2, "Forwarded"))).to eq("203.0.113.50")
      end

      it "unwraps a quoted IPv6 for= with brackets and port" do
        env = {
          "REMOTE_ADDR" => "2001:db8::1",
          "HTTP_FORWARDED" => 'for="[2606:4700:4700::1111]:443"',
        }
        expect(Otto::Utils.resolve_client_ip(env, depth_config(1, "Forwarded"))).to eq("2606:4700:4700::1111")
      end

      it "ignores other params and is case-insensitive about the for= key" do
        env = {
          "REMOTE_ADDR" => "10.0.0.1",
          "HTTP_FORWARDED" => "For=203.0.113.50;proto=https;by=10.0.0.1",
        }
        expect(Otto::Utils.resolve_client_ip(env, depth_config(1, "Forwarded"))).to eq("203.0.113.50")
      end

      it "ignores a forged leftmost entry (padding-robust, counts from right)" do
        env = {
          "REMOTE_ADDR" => "10.0.0.1",
          "HTTP_FORWARDED" => "for=9.9.9.9, for=203.0.113.50",
        }
        expect(Otto::Utils.resolve_client_ip(env, depth_config(1, "Forwarded"))).to eq("203.0.113.50")
      end

      it "counts elements without a for= as raw positions (no index shift)" do
        env = {
          "REMOTE_ADDR" => "10.0.0.1",
          "HTTP_FORWARDED" => "proto=https, for=203.0.113.50",
        }
        expect(Otto::Utils.resolve_client_ip(env, depth_config(1, "Forwarded"))).to eq("203.0.113.50")
      end

      it "falls back to REMOTE_ADDR when the selected entry is obfuscated/unknown" do
        env = {
          "REMOTE_ADDR" => "10.0.0.1",
          "HTTP_FORWARDED" => "for=203.0.113.50, for=_hidden",
        }
        expect(Otto::Utils.resolve_client_ip(env, depth_config(1, "Forwarded"))).to eq("10.0.0.1")
      end

      it "falls back to REMOTE_ADDR on a short chain" do
        env = { "REMOTE_ADDR" => "10.0.0.1", "HTTP_FORWARDED" => "for=203.0.113.50" }
        expect(Otto::Utils.resolve_client_ip(env, depth_config(2, "Forwarded"))).to eq("10.0.0.1")
      end

      it "falls back to REMOTE_ADDR when the Forwarded header is absent" do
        env = { "REMOTE_ADDR" => "10.0.0.1", "HTTP_X_FORWARDED_FOR" => "203.0.113.50" }
        expect(Otto::Utils.resolve_client_ip(env, depth_config(1, "Forwarded"))).to eq("10.0.0.1")
      end

      it "ignores X-Forwarded-For entirely (Forwarded only)" do
        env = {
          "REMOTE_ADDR" => "10.0.0.1",
          "HTTP_FORWARDED" => "for=203.0.113.50",
          "HTTP_X_FORWARDED_FOR" => "9.9.9.9",
        }
        expect(Otto::Utils.resolve_client_ip(env, depth_config(1, "Forwarded"))).to eq("203.0.113.50")
      end
    end

    context "header = 'Both'" do
      it "prefers the Forwarded header when it carries a for=" do
        env = {
          "REMOTE_ADDR" => "10.0.0.1",
          "HTTP_FORWARDED" => "for=203.0.113.50",
          "HTTP_X_FORWARDED_FOR" => "9.9.9.9, 8.8.8.8",
        }
        expect(Otto::Utils.resolve_client_ip(env, depth_config(1, "Both"))).to eq("203.0.113.50")
      end

      it "falls back to X-Forwarded-For when Forwarded is absent" do
        env = { "REMOTE_ADDR" => "10.0.0.1", "HTTP_X_FORWARDED_FOR" => "203.0.113.50" }
        expect(Otto::Utils.resolve_client_ip(env, depth_config(1, "Both"))).to eq("203.0.113.50")
      end

      it "falls back to X-Forwarded-For when Forwarded has no for= param" do
        env = {
          "REMOTE_ADDR" => "10.0.0.1",
          "HTTP_FORWARDED" => "proto=https",
          "HTTP_X_FORWARDED_FOR" => "203.0.113.50",
        }
        expect(Otto::Utils.resolve_client_ip(env, depth_config(1, "Both"))).to eq("203.0.113.50")
      end

      it "does not merge chains: a present Forwarded shadows X-Forwarded-For" do
        # depth 2 against Forwarded alone (1 hop + peer) is a short chain → peer,
        # proving XFF was not appended to extend the Forwarded chain.
        env = {
          "REMOTE_ADDR" => "10.0.0.1",
          "HTTP_FORWARDED" => "for=203.0.113.50",
          "HTTP_X_FORWARDED_FOR" => "198.51.100.7, 198.51.100.8",
        }
        expect(Otto::Utils.resolve_client_ip(env, depth_config(2, "Both"))).to eq("10.0.0.1")
      end
    end

    it "defaults to X-Forwarded-For when no header is configured" do
      cfg = Otto::Security::Config.new
      cfg.trusted_proxy_depth = 1
      env = { "REMOTE_ADDR" => "10.0.0.1", "HTTP_X_FORWARDED_FOR" => "203.0.113.50" }
      expect(Otto::Utils.resolve_client_ip(env, cfg)).to eq("203.0.113.50")
    end
  end
end
