#!/usr/bin/env ruby
# frozen_string_literal: true

# Example: Long-Polling with Otto
#
# This example demonstrates long-polling as a SIMPLE alternative to SSE/WebSocket
# for low-to-medium frequency updates. Long-polling works perfectly with Otto's
# synchronous, stateless design.
#
# Use Cases:
# - Dashboard metrics (update every 10-60 seconds)
# - Notification polling (check for new notifications)
# - Job status polling (background job progress)
# - Chat messages (low-volume, <10 msgs/min)
#
# When NOT to use:
# - High-frequency updates (>1/second) → Use SSE
# - Bidirectional communication (chat rooms) → Use WebSocket
# - Instant notifications (<100ms latency) → Use SSE/WebSocket
#
# Architecture:
# ┌─────────────────┐
# │   Otto API      │  ← Stateless HTTP (no external dependencies)
# │   (Any server)  │
# └─────────────────┘
#         ↓
#    ┌─────────┐
#    │  Redis  │  ← Optional (for multi-server deployments)
#    │  (list) │
#    └─────────┘
#
# Benefits vs SSE/WebSocket:
# - Works with Otto's synchronous model (no streaming required)
# - Compatible with any Rack server (Puma, Unicorn, Passenger)
# - HTTP-based (cacheable, proxy-friendly, standard tooling)
# - Simple implementation (no async server, no hijacking)
# - Easy debugging (standard HTTP requests/responses)
#
# Trade-offs:
# - Higher latency than SSE/WebSocket (poll interval)
# - More server requests (reconnect on each poll)
# - Less efficient for high-frequency updates

require 'bundler/inline'

gemfile do
  source 'https://rubygems.org'
  gem 'otto', path: '../'
  gem 'redis'
  gem 'puma'
end

# ============================================================================
# Example 1: Notification Polling (In-Memory)
# ============================================================================

# Routes
NOTIFICATION_ROUTES = <<~ROUTES
  # Authentication
  POST /api/auth/login                    LoginLogic response=json

  # Notification endpoints
  GET  /api/notifications/poll            NotificationPollLogic response=json auth=session
  POST /api/notifications                 CreateNotificationLogic response=json auth=session
  GET  /api/notifications                 ListNotificationsLogic response=json auth=session
ROUTES

# Simple in-memory storage (replace with database in production)
class NotificationStore
  @notifications = []
  @mutex = Mutex.new

  class << self
    def add(user_id, message)
      @mutex.synchronize do
        @notifications << {
          id: @notifications.size + 1,
          user_id: user_id,
          message: message,
          timestamp: Time.now.iso8601,
          read: false
        }
      end
    end

    def get_since(user_id, last_id = 0)
      @mutex.synchronize do
        @notifications.select do |n|
          n[:user_id] == user_id && n[:id] > last_id
        end
      end
    end

    def get_all(user_id)
      @mutex.synchronize do
        @notifications.select { |n| n[:user_id] == user_id }
      end
    end
  end
end

# Logic classes
class LoginLogic < Otto::RequestContext
  def call
    user_id = params[:user_id]&.to_i || 1
    session[:user_id] = user_id
    { success: true, user_id: user_id }
  end
end

class NotificationPollLogic < Otto::RequestContext
  def call
    user_id = session[:user_id]
    raise_concern('Unauthorized', status: 401) unless user_id

    # Long-polling parameters
    timeout = params[:timeout].to_i.clamp(1, 30)  # Max 30s wait
    last_id = params[:last_id].to_i               # Client's last seen notification ID

    # Long-polling loop
    start_time = Time.now
    loop do
      # Check for new notifications
      notifications = NotificationStore.get_since(user_id, last_id)

      # Return immediately if we have new data
      if notifications.any?
        return {
          success: true,
          notifications: notifications,
          last_id: notifications.last[:id],
          poll_again_in: 0 # Client should poll again immediately
        }
      end

      # Check timeout
      elapsed = Time.now - start_time
      break if elapsed >= timeout

      # Wait before checking again (reduces CPU/DB load)
      sleep 0.5
    end

    # Timeout reached, return empty
    {
      success: true,
      notifications: [],
      last_id: last_id,
      poll_again_in: 5 # Client should poll again in 5 seconds
    }
  end
end

class CreateNotificationLogic < Otto::RequestContext
  def call
    user_id = session[:user_id]
    raise_concern('Unauthorized', status: 401) unless user_id

    target_user = params[:target_user_id]&.to_i || user_id
    message = params[:message]

    NotificationStore.add(target_user, message)

    { success: true }
  end
end

class ListNotificationsLogic < Otto::RequestContext
  def call
    user_id = session[:user_id]
    raise_concern('Unauthorized', status: 401) unless user_id

    notifications = NotificationStore.get_all(user_id)

    {
      success: true,
      notifications: notifications,
      last_id: notifications.last&.dig(:id) || 0
    }
  end
end

# ============================================================================
# Example 2: Job Status Polling (Redis-backed)
# ============================================================================

JOB_ROUTES = <<~ROUTES
  # Job management
  POST /api/jobs                          CreateJobLogic response=json auth=session
  GET  /api/jobs/:job_id/status           JobStatusLogic response=json auth=session
  GET  /api/jobs/:job_id/poll             JobPollLogic response=json auth=session
ROUTES

# Redis-backed job storage (for multi-server deployments)
class JobStore
  def initialize(redis_url = 'redis://localhost:6379/0')
    @redis = Redis.new(url: redis_url)
  end

  def create_job(user_id, job_type)
    job_id = SecureRandom.uuid
    job_data = {
      id: job_id,
      user_id: user_id,
      type: job_type,
      status: 'pending',
      progress: 0,
      created_at: Time.now.iso8601
    }

    @redis.set("job:#{job_id}", job_data.to_json)
    @redis.expire("job:#{job_id}", 3600) # Expire after 1 hour

    job_id
  end

  def update_job(job_id, status:, progress: nil, result: nil)
    job_json = @redis.get("job:#{job_id}")
    return nil unless job_json

    job_data = JSON.parse(job_json)
    job_data['status'] = status
    job_data['progress'] = progress if progress
    job_data['result'] = result if result
    job_data['updated_at'] = Time.now.iso8601

    @redis.set("job:#{job_id}", job_data.to_json)
    @redis.expire("job:#{job_id}", 3600)

    job_data
  end

  def get_job(job_id)
    job_json = @redis.get("job:#{job_id}")
    job_json ? JSON.parse(job_json) : nil
  end
end

class CreateJobLogic < Otto::RequestContext
  def call
    user_id = session[:user_id]
    raise_concern('Unauthorized', status: 401) unless user_id

    job_type = params[:type] || 'generic'
    job_id = job_store.create_job(user_id, job_type)

    # Simulate background job execution
    Thread.new do
      sleep 2
      job_store.update_job(job_id, status: 'processing', progress: 25)
      sleep 2
      job_store.update_job(job_id, status: 'processing', progress: 50)
      sleep 2
      job_store.update_job(job_id, status: 'processing', progress: 75)
      sleep 2
      job_store.update_job(job_id, status: 'completed', progress: 100, result: 'Success!')
    end

    {
      success: true,
      job_id: job_id,
      poll_url: "/api/jobs/#{job_id}/poll"
    }
  end

  private

  def job_store
    @job_store ||= JobStore.new
  end
end

class JobStatusLogic < Otto::RequestContext
  def call
    user_id = session[:user_id]
    raise_concern('Unauthorized', status: 401) unless user_id

    job_id = params[:job_id]
    job = job_store.get_job(job_id)

    raise_concern('Job not found', status: 404) unless job
    raise_concern('Forbidden', status: 403) unless job['user_id'] == user_id

    { success: true, job: job }
  end

  private

  def job_store
    @job_store ||= JobStore.new
  end
end

class JobPollLogic < Otto::RequestContext
  def call
    user_id = session[:user_id]
    raise_concern('Unauthorized', status: 401) unless user_id

    job_id = params[:job_id]
    timeout = params[:timeout].to_i.clamp(1, 30)
    last_status = params[:last_status]

    # Long-polling loop
    start_time = Time.now
    loop do
      job = job_store.get_job(job_id)
      raise_concern('Job not found', status: 404) unless job
      raise_concern('Forbidden', status: 403) unless job['user_id'] == user_id

      # Return immediately if status changed or job completed
      if job['status'] != last_status || job['status'] == 'completed' || job['status'] == 'failed'
        return {
          success: true,
          job: job,
          poll_again: job['status'] != 'completed' && job['status'] != 'failed'
        }
      end

      # Check timeout
      elapsed = Time.now - start_time
      break if elapsed >= timeout

      sleep 0.5
    end

    # Timeout reached, return current state
    job = job_store.get_job(job_id)
    {
      success: true,
      job: job,
      poll_again: true
    }
  end

  private

  def job_store
    @job_store ||= JobStore.new
  end
end

# ============================================================================
# Client-Side JavaScript Examples
# ============================================================================

CLIENT_SIDE_JS = <<~JAVASCRIPT
  // ========================================================================
  // Example 1: Notification Polling
  // ========================================================================

  class NotificationPoller {
    constructor(pollUrl) {
      this.pollUrl = pollUrl;
      this.lastId = 0;
      this.isPolling = false;
      this.listeners = [];
    }

    start() {
      if (this.isPolling) return;
      this.isPolling = true;
      this.poll();
    }

    stop() {
      this.isPolling = false;
    }

    onNotification(callback) {
      this.listeners.push(callback);
    }

    async poll() {
      while (this.isPolling) {
        try {
          const response = await fetch(
            `${this.pollUrl}?timeout=30&last_id=${this.lastId}`,
            { credentials: 'include' }
          );

          const data = await response.json();

          if (data.notifications && data.notifications.length > 0) {
            // Process new notifications
            data.notifications.forEach(notif => {
              this.listeners.forEach(cb => cb(notif));
            });

            // Update last seen ID
            this.lastId = data.last_id;

            // Poll again immediately if suggested
            if (data.poll_again_in === 0) {
              continue;
            }
          }

          // Wait before next poll (if suggested)
          if (data.poll_again_in > 0) {
            await this.sleep(data.poll_again_in * 1000);
          }
        } catch (error) {
          console.error('Polling error:', error);
          // Wait longer on error (exponential backoff)
          await this.sleep(5000);
        }
      }
    }

    sleep(ms) {
      return new Promise(resolve => setTimeout(resolve, ms));
    }
  }

  // Usage:
  // const poller = new NotificationPoller('/api/notifications/poll');
  // poller.onNotification(notif => {
  //   console.log('New notification:', notif);
  //   showToast(notif.message);
  // });
  // poller.start();

  // ========================================================================
  // Example 2: Job Status Polling
  // ========================================================================

  class JobPoller {
    constructor(jobId, pollUrl) {
      this.jobId = jobId;
      this.pollUrl = pollUrl;
      this.lastStatus = null;
      this.listeners = [];
    }

    onProgress(callback) {
      this.listeners.push(callback);
      return this;
    }

    async pollUntilComplete() {
      while (true) {
        try {
          const response = await fetch(
            `${this.pollUrl}?timeout=30&last_status=${this.lastStatus || ''}`,
            { credentials: 'include' }
          );

          const data = await response.json();

          if (data.job) {
            // Notify listeners
            this.listeners.forEach(cb => cb(data.job));

            // Update last status
            this.lastStatus = data.job.status;

            // Stop polling if job completed
            if (!data.poll_again) {
              return data.job;
            }
          }
        } catch (error) {
          console.error('Job polling error:', error);
          await this.sleep(5000);
        }
      }
    }

    sleep(ms) {
      return new Promise(resolve => setTimeout(resolve, ms));
    }
  }

  // Usage:
  // const jobPoller = new JobPoller(jobId, `/api/jobs/${jobId}/poll`);
  // jobPoller
  //   .onProgress(job => {
  //     console.log(`Progress: ${job.progress}%`);
  //     updateProgressBar(job.progress);
  //   })
  //   .pollUntilComplete()
  //   .then(job => {
  //     console.log('Job completed:', job);
  //     showSuccessMessage(job.result);
  //   });

  // ========================================================================
  // Example 3: Adaptive Polling (smart backoff)
  // ========================================================================

  class AdaptivePoller {
    constructor(pollUrl, options = {}) {
      this.pollUrl = pollUrl;
      this.minInterval = options.minInterval || 1000;  // 1s
      this.maxInterval = options.maxInterval || 60000; // 60s
      this.currentInterval = this.minInterval;
      this.isPolling = false;
    }

    start() {
      if (this.isPolling) return;
      this.isPolling = true;
      this.poll();
    }

    stop() {
      this.isPolling = false;
    }

    async poll() {
      while (this.isPolling) {
        const startTime = Date.now();

        try {
          const response = await fetch(this.pollUrl, {
            credentials: 'include'
          });

          const data = await response.json();
          const hasNewData = this.processData(data);

          // Adaptive interval adjustment
          if (hasNewData) {
            // Data arrived, decrease interval (poll more frequently)
            this.currentInterval = Math.max(
              this.minInterval,
              this.currentInterval / 2
            );
          } else {
            // No data, increase interval (poll less frequently)
            this.currentInterval = Math.min(
              this.maxInterval,
              this.currentInterval * 1.5
            );
          }

          console.log(`Next poll in ${this.currentInterval}ms`);
        } catch (error) {
          console.error('Polling error:', error);
          // On error, back off exponentially
          this.currentInterval = Math.min(
            this.maxInterval,
            this.currentInterval * 2
          );
        }

        // Wait for next poll
        await this.sleep(this.currentInterval);
      }
    }

    processData(data) {
      // Override this method in subclass
      return false;
    }

    sleep(ms) {
      return new Promise(resolve => setTimeout(resolve, ms));
    }
  }
JAVASCRIPT

# ============================================================================
# Performance Comparison
# ============================================================================

PERFORMANCE_COMPARISON = <<~MARKDOWN
  # Performance Comparison: Long-Polling vs SSE vs WebSocket

  ## Scenario: 1000 concurrent clients, 1 message/minute average

  ### Long-Polling (30s timeout)
  - Requests/second: 1000 clients / 30s = 33.3 req/s
  - Connection overhead: New TCP connection every 30s
  - Latency: 0-30s (average 15s)
  - Server resources: 33 concurrent requests (handled by thread pool)
  - Bandwidth: ~1KB/request * 33 req/s = 33 KB/s

  **Suitable for**: Up to 10,000 clients on standard Puma (5 workers * 32 threads)

  ### SSE (Server-Sent Events)
  - Requests/second: 0 (persistent connection)
  - Connection overhead: 1 TCP connection per client (persistent)
  - Latency: <100ms (near-instant)
  - Server resources: 1000 persistent connections (requires async server)
  - Bandwidth: ~10 bytes/s heartbeat * 1000 = 10 KB/s + message data

  **Suitable for**: 10,000+ clients on async server (Falcon, Iodine)

  ### WebSocket
  - Requests/second: 0 (persistent connection)
  - Connection overhead: 1 TCP connection per client (persistent)
  - Latency: <50ms (instant, bidirectional)
  - Server resources: 1000 persistent connections (requires async server)
  - Bandwidth: Similar to SSE, but bidirectional

  **Suitable for**: 10,000+ clients on async server (Falcon, Iodine)

  ## Key Takeaway

  Long-polling is perfectly viable for:
  - Low-to-medium frequency updates (<1/second)
  - Moderate concurrency (<10,000 clients)
  - Simple deployment (works with Otto's synchronous model)

  SSE/WebSocket are necessary for:
  - High-frequency updates (>1/second)
  - High concurrency (>10,000 clients)
  - Real-time requirements (<100ms latency)
MARKDOWN

# ============================================================================
# Running the Example
# ============================================================================

if __FILE__ == $PROGRAM_NAME
  puts "Long-Polling with Otto Example"
  puts "=" * 80
  puts

  example = ARGV[0]

  case example
  when 'notifications'
    puts "Starting notification polling example..."
    puts "Routes:"
    puts NOTIFICATION_ROUTES
    puts

    require 'tempfile'
    routes_file = Tempfile.new(['routes', '.txt'])
    routes_file.write(NOTIFICATION_ROUTES)
    routes_file.close

    otto = Otto.new(routes_file.path)
    otto.enable_sessions!(secret: 'dev_secret')

    puts "Server running on http://localhost:4567"
    puts
    puts "Try these commands:"
    puts
    puts "  # Login"
    puts "  curl -X POST http://localhost:4567/api/auth/login \\"
    puts "    -H 'Content-Type: application/json' \\"
    puts "    -d '{\"user_id\": 1}' \\"
    puts "    -c cookies.txt"
    puts
    puts "  # Start polling (in another terminal, keeps connection open)"
    puts "  curl -b cookies.txt 'http://localhost:4567/api/notifications/poll?timeout=30&last_id=0'"
    puts
    puts "  # Create notification (in another terminal)"
    puts "  curl -X POST http://localhost:4567/api/notifications \\"
    puts "    -H 'Content-Type: application/json' \\"
    puts "    -d '{\"message\": \"Hello from long-polling!\"}' \\"
    puts "    -b cookies.txt"
    puts

    Rack::Handler::Puma.run(otto, Port: 4567, Threads: '0:16')

  when 'jobs'
    puts "Starting job polling example..."
    puts "Routes:"
    puts JOB_ROUTES
    puts

    require 'tempfile'
    require 'securerandom'
    routes_file = Tempfile.new(['routes', '.txt'])
    routes_file.write(JOB_ROUTES)
    routes_file.close

    otto = Otto.new(routes_file.path)
    otto.enable_sessions!(secret: 'dev_secret')

    puts "Server running on http://localhost:4567"
    puts
    puts "Try these commands:"
    puts
    puts "  # Login"
    puts "  curl -X POST http://localhost:4567/api/auth/login \\"
    puts "    -H 'Content-Type: application/json' \\"
    puts "    -d '{\"user_id\": 1}' \\"
    puts "    -c cookies.txt"
    puts
    puts "  # Create job"
    puts "  curl -X POST http://localhost:4567/api/jobs \\"
    puts "    -H 'Content-Type: application/json' \\"
    puts "    -d '{\"type\": \"export\"}' \\"
    puts "    -b cookies.txt"
    puts "  # => {\"success\": true, \"job_id\": \"...\", \"poll_url\": \"/api/jobs/.../poll\"}"
    puts
    puts "  # Poll job status (replace JOB_ID)"
    puts "  curl -b cookies.txt 'http://localhost:4567/api/jobs/JOB_ID/poll?timeout=30'"
    puts

    Rack::Handler::Puma.run(otto, Port: 4567, Threads: '0:16')

  else
    puts "Usage:"
    puts "  ruby #{__FILE__} notifications    # Notification polling example"
    puts "  ruby #{__FILE__} jobs             # Job status polling example"
    puts
    puts "Client-side JavaScript examples:"
    puts CLIENT_SIDE_JS
    puts
    puts "Performance comparison:"
    puts PERFORMANCE_COMPARISON
    exit 1
  end
end
