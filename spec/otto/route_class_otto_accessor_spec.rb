# spec/otto/route_class_otto_accessor_spec.rb
#
# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Otto::Route::ClassMethods do
  let(:target_class) { Class.new { extend Otto::Route::ClassMethods } }

  it 'reads back the value just assigned' do
    otto_instance = instance_double(Otto)
    target_class.otto = otto_instance
    expect(target_class.otto).to eq(otto_instance)
  end

  it 'returns nil before any assignment' do
    expect(target_class.otto).to be_nil
  end

  it 'keeps separate target classes independent' do
    other_class = Class.new { extend Otto::Route::ClassMethods }
    otto_1      = instance_double(Otto)
    otto_2      = instance_double(Otto)

    target_class.otto = otto_1
    other_class.otto  = otto_2

    expect(target_class.otto).to eq(otto_1)
    expect(other_class.otto).to eq(otto_2)
  end

  it 'isolates concurrent threads instead of racing on shared class state (issue #188)' do
    otto_a = instance_double(Otto)
    otto_b = instance_double(Otto)
    observed_a = nil
    observed_b = nil

    # Two "requests" for two different Otto instances dispatch through the
    # same target class concurrently. With a plain class ivar, thread_b's
    # assignment clobbers thread_a's for the duration of thread_a's request.
    thread_a = Thread.new do
      target_class.otto = otto_a
      sleep 0.05
      observed_a = target_class.otto
    end

    thread_b = Thread.new do
      sleep 0.02
      target_class.otto = otto_b
      observed_b = target_class.otto
    end

    [thread_a, thread_b].each(&:join)

    expect(observed_a).to eq(otto_a)
    expect(observed_b).to eq(otto_b)
  end
end
