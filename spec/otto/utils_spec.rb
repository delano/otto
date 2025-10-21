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
end
