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
    #
    # The interleaving is forced deterministically with Queue handoffs (no
    # sleep-based timing, which flakes on loaded CI): thread_a assigns, THEN
    # thread_b assigns (which would overwrite a shared slot), and only THEN
    # thread_a reads back — so a shared ivar would make thread_a observe
    # otto_b. Fiber/thread-local storage keeps each thread on its own value.
    a_assigned = Queue.new
    b_assigned = Queue.new

    thread_a = Thread.new do
      target_class.otto = otto_a
      a_assigned.push(true)   # let thread_b assign now
      b_assigned.pop          # wait until thread_b has assigned (would clobber)
      observed_a = target_class.otto
    end

    thread_b = Thread.new do
      a_assigned.pop          # wait until thread_a has assigned
      target_class.otto = otto_b
      observed_b = target_class.otto
      b_assigned.push(true)   # release thread_a to read back
    end

    [thread_a, thread_b].each(&:join)

    expect(observed_a).to eq(otto_a)
    expect(observed_b).to eq(otto_b)
  end
end
