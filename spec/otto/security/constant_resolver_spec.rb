# spec/otto/security/constant_resolver_spec.rb
#
# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Otto::Security::ConstantResolver do
  describe '.safe_const_get' do
    context 'with valid class names' do
      it 'resolves a top-level class' do
        expect(described_class.safe_const_get('String')).to eq(String)
      end

      it 'resolves a namespaced class' do
        expect(described_class.safe_const_get('Otto::Route')).to eq(Otto::Route)
      end
    end

    context 'with malformed names' do
      [
        'lowercase',
        'has space',
        '::LeadingColons',
        'Trailing::',
        '1Numeric',
        'Has-Dash',
        "New\nLine",
        '',
      ].each do |bad|
        it "rejects #{bad.inspect} with an invalid-format error" do
          expect { described_class.safe_const_get(bad) }
            .to raise_error(ArgumentError, /Invalid class name format|Forbidden class name/)
        end
      end
    end

    context 'with forbidden classes named directly' do
      %w[Kernel Module Class Object BasicObject File Dir IO Process Binding Proc Method Thread Fiber ObjectSpace GC].each do |forbidden|
        it "rejects #{forbidden}" do
          expect { described_class.safe_const_get(forbidden) }
            .to raise_error(ArgumentError, /Forbidden class name/)
        end
      end
    end

    context 'with forbidden classes reached via a namespace prefix (bypass hardening)' do
      # These resolve to the SAME forbidden constant object through Object's
      # namespace / constant inheritance, so a literal-string blocklist misses
      # them. The resolved-constant identity check must still reject them.
      %w[Object::Kernel Object::File Object::Process Object::IO Object::Dir Object::Object].each do |bypass|
        it "rejects #{bypass}" do
          expect { described_class.safe_const_get(bypass) }
            .to raise_error(ArgumentError, /Forbidden class name/)
        end
      end
    end

    context 'with unknown classes' do
      it 'raises a class-not-found error' do
        expect { described_class.safe_const_get('Otto::DefinitelyNotAClass123') }
          .to raise_error(ArgumentError, /Class not found/)
      end
    end

    context "with an app's own class that merely shares a forbidden name" do
      it 'allows a distinct constant object that is not the forbidden built-in' do
        stub_const('SafeResolverApp::File', Class.new)
        expect(described_class.safe_const_get('SafeResolverApp::File'))
          .to eq(SafeResolverApp::File)
        expect(described_class.safe_const_get('SafeResolverApp::File')).not_to eq(::File)
      end
    end
  end
end
