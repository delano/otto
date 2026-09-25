# spec/otto/security/trusted_proxy_config_spec.rb
#
# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Otto::Security::TrustedProxyConfig do
  subject(:tp) { described_class.new }

  describe 'defaults' do
    it 'starts unconfigured with the X-Forwarded-For header' do
      expect(tp.mode).to be_nil
      expect(tp).not_to be_configured
      expect(tp.proxies).to eq([])
      expect(tp.depth).to be_nil
      expect(tp.header).to eq('X-Forwarded-For')
      expect(tp).to be_default_header
      expect(tp).not_to be_forwarding_family_dependent
    end
  end

  describe '#mode' do
    it 'is :filter once an entry is added' do
      tp.add('10.0.0.0/8')
      expect(tp.mode).to eq(:filter)
      expect(tp).to be_forwarding_family_dependent
    end

    it 'is :depth for a depth >= 1' do
      tp.depth = 2
      expect(tp.mode).to eq(:depth)
      expect(tp).to be_forwarding_family_dependent
    end

    it 'stays unconfigured for a depth of 0' do
      tp.depth = 0
      expect(tp.mode).to be_nil
    end

    it 'is :none after trust_none!, which reads no forwarded chain' do
      tp.trust_none!
      expect(tp.mode).to eq(:none)
      expect(tp).to be_configured
      expect(tp).not_to be_forwarding_family_dependent
    end

    it 'returns to unconfigured when depth is cleared' do
      tp.depth = 2
      tp.depth = nil
      expect(tp.mode).to be_nil
    end
  end

  describe 'mode exclusivity' do
    # Each pair is refused in both assignment orders, with the same message.
    # Steps are [method, *args] sent to the object under test.
    {
      'filter then depth' => [[:add, '10.0.0.0/8'], [:depth=, 1], /Cannot configure both/],
      'depth then filter' => [[:depth=, 1], [:add, '10.0.0.0/8'], /Cannot configure both/],
      'none then filter' => [[:trust_none!], [:add, '10.0.0.0/8'], /Cannot combine/],
      'filter then none' => [[:add, '10.0.0.0/8'], [:trust_none!], /Cannot combine/],
      'none then depth' => [[:trust_none!], [:depth=, 1], /Cannot combine/],
      'depth then none' => [[:depth=, 1], [:trust_none!], /Cannot combine/],
      'header then filter' => [[:header=, 'Forwarded'], [:add, '10.0.0.0/8'], /'Forwarded' or 'Both'/],
      'filter then header' => [[:add, '10.0.0.0/8'], [:header=, 'Both'], /'Forwarded' or 'Both'/],
    }.each do |label, (first, second, message)|
      it "refuses #{label} and leaves the first setting in place" do
        tp.public_send(*first)
        before = [tp.mode, tp.proxies.dup, tp.depth, tp.header]

        expect { tp.public_send(*second) }.to raise_error(ArgumentError, message)
        expect([tp.mode, tp.proxies, tp.depth, tp.header]).to eq(before)
      end
    end

    it 'claims filter mode for an empty list, so the conflict surfaces at that call' do
      tp.depth = 1
      expect { tp.add([]) }.to raise_error(ArgumentError, /Cannot configure both/)
    end

    it 'allows a depth of 0 alongside entries' do
      tp.add('10.0.0.0/8')
      expect { tp.depth = 0 }.not_to raise_error
      expect(tp.mode).to eq(:filter)
    end

    it 'allows a non-default header in depth mode' do
      tp.depth = 1
      expect { tp.header = 'Forwarded' }.not_to raise_error
    end
  end

  describe '#add' do
    it 'validates the whole list before registering any entry' do
      expect { tp.add(['10.0.0.0/8', 'none']) }.to raise_error(ArgumentError, /trust-nobody assertion/)
      expect(tp.proxies).to be_empty
      expect(tp).not_to be_filter
    end

    it 'rejects an unsupported type' do
      expect { tp.add(42) }.to raise_error(ArgumentError, 'Proxy must be a String, Regexp, or Array')
    end
  end

  describe '#check_depth! and #check_header!' do
    it 'validate without storing' do
      expect(tp.check_depth!(3)).to eq(3)
      expect(tp.check_header!(' forwarded ')).to eq('Forwarded')
      expect(tp.depth).to be_nil
      expect(tp.header).to eq('X-Forwarded-For')
    end

    it 'reject an invalid depth by type and range' do
      expect { tp.check_depth!('2') }.to raise_error(ArgumentError, /must be an Integer or nil, got String/)
      expect { tp.check_depth!(-1) }.to raise_error(ArgumentError, /must be >= 0/)
    end

    it 'reject an unrecognized header' do
      expect { tp.check_header!('bogus') }.to raise_error(ArgumentError, /must be one of/)
    end
  end

  describe '#trusted?' do
    before { tp.add(['10.0.0.0/8', /\A172\.16\./, '192.168.']) }

    it 'matches CIDR containment, Regexp, and legacy prefix entries' do
      expect(tp.trusted?('10.1.2.3')).to be true
      expect(tp.trusted?('::ffff:10.1.2.3')).to be true
      expect(tp.trusted?('172.16.0.9')).to be true
      expect(tp.trusted?('192.168.1.1')).to be true
      expect(tp.trusted?('8.8.8.8')).to be false
      expect(tp.trusted?(nil)).to be false
    end
  end

  describe '#validate!' do
    it 'passes for a coherent configuration' do
      tp.depth = 2
      tp.header = 'Both'
      expect { tp.validate! }.not_to raise_error
    end

    it 'backstops a mode conflict written past the mutators' do
      tp.add('10.0.0.0/8')
      tp.instance_variable_set(:@depth, 1)
      expect { tp.validate! }.to raise_error(ArgumentError, /Cannot configure both/)
    end

    it 'backstops a non-canonical header written past the mutators' do
      tp.instance_variable_set(:@header, 'forwarded') # not canonical
      expect { tp.validate! }.to raise_error(ArgumentError, /must be one of/)
    end
  end

  describe 'freezing' do
    it 'refuses every mutator once frozen' do
      tp.deep_freeze!

      expect { tp.add('10.0.0.0/8') }.to raise_error(FrozenError)
      expect { tp.depth = 1 }.to raise_error(FrozenError)
      expect { tp.header = 'Forwarded' }.to raise_error(FrozenError)
      expect { tp.trust_none! }.to raise_error(FrozenError)
      expect(tp.proxies).to be_frozen
    end
  end

  describe 'Otto::Security::Config integration' do
    let(:config) { Otto::Security::Config.new }

    it 'delegates the public trusted-proxy API and reports the mode' do
      config.trusted_proxy_depth = 2

      expect(config.trusted_proxy_mode).to eq(:depth)
      expect(config.trusted_proxy_depth).to eq(2)
      expect(config).to be_trusted_proxy_depth_mode
    end

    it 'does not expose the object, whose setters would skip Config checks' do
      expect(config).not_to respond_to(:trusted_proxy_config)
    end

    it 'keeps the message constants reachable on Config' do
      expect(Otto::Security::Config::PROXY_MODE_CONFLICT_MESSAGE)
        .to equal(described_class::PROXY_MODE_CONFLICT_MESSAGE)
      expect(Otto::Security::Config::TRUSTED_PROXY_HEADERS).to equal(described_class::HEADERS)
    end
  end
end
