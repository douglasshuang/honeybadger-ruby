require 'forwardable'
require 'net/http'

require 'honeybadger/logging'

module Honeybadger
  # A concurrent queue to notify the backend.
  # @api private
  class EventsWorker
    extend Forwardable

    include Honeybadger::Logging::Helper

    # Sub-class thread so we have a named thread (useful for debugging in Thread.list).
    class Thread < ::Thread; end

    # Used to signal the worker to shutdown.
    SHUTDOWN = :__hb_worker_shutdown!

    # The base number for the exponential backoff formula when calculating the
    # throttle interval. `1.05 ** throttle` will reach an interval of 2 minutes
    # after around 100 429 responses from the server.
    BASE_THROTTLE = 1.05

    SEND_TIMEOUT = 30
    MAX_EVENTS = 200
    MAX_EVENTS_SIZE = 400_000


    def initialize(config)
      @config = config
      @throttle = 0
      @throttle_interval = 0
      @mutex = Mutex.new
      @marker = ConditionVariable.new
      @queue = Queue.new
      @send_queue = Queue.new
      @shutdown = false
      @start_at = nil
      @pid = Process.pid
    end

    def push(msg)
      return false unless start

      if queue.size >= config.max_queue_size
        warn { sprintf('Unable to report error; reached max queue size of %s. id=%s', queue.size, msg.id) }
        return false
      end

      queue.push(msg)
    end

    def send_now(msg)
      handle_response(msg, send_to_backend(msg))
    end

    def shutdown(force = false)
      d { 'shutting down worker' }

      mutex.synchronize do
        @shutdown = true
      end

      return true if force
      return true unless thread&.alive?

      if throttled?
        warn { sprintf('Unable to report %s error(s) to Honeybadger (currently throttled)', queue.size) } unless queue.empty?
        return true
      end

      info { sprintf('Waiting to report %s error(s) to Honeybadger', queue.size) } unless queue.empty?

      queue.push(SHUTDOWN)
      !!thread.join
    ensure
      queue.clear
      kill!
    end

    # Blocks until queue is processed up to this point in time.
    def flush
      mutex.synchronize do
        if thread && thread.alive?
          queue.push(marker)
          marker.wait(mutex)
        end
      end
    end

    def start
      return false unless can_start?

      mutex.synchronize do
        @shutdown = false
        @start_at = nil

        return true if thread&.alive?

        @pid = Process.pid
        @thread = Thread.new { run }
      end

      true
    end

    private

    attr_reader :config, :queue, :pid, :mutex, :marker, :thread, :throttle,
      :throttle_interval, :start_at

    def_delegator :config, :backend

    def shutdown?
      mutex.synchronize { @shutdown }
    end

    def suspended?
      mutex.synchronize { start_at && Time.now.to_i < start_at }
    end

    def can_start?
      return false if shutdown?
      return false if suspended?
      true
    end

    def throttled?
      mutex.synchronize { throttle > 0 }
    end

    def kill!
      d { 'killing worker thread' }

      if thread
        Thread.kill(thread)
        thread.join # Allow ensure blocks to execute.
      end

      true
    end

    def suspend(interval)
      mutex.synchronize do
        @start_at = Time.now.to_i + interval
        queue.clear
      end

      # Must be performed last since this may kill the current thread.
      kill!
    end

    def run
      begin
        d { 'worker started' }
        Thread.current.thread_variable_set(:last_sent, Time.now)
        Thread.current.thread_variable_set(:send_queue, [])

        loop do
          case msg = queue.pop
          when SHUTDOWN then break
          when ConditionVariable then signal_marker(msg)
          else work(msg)
          end
        end
      ensure
        d { 'stopping worker' }
      end
    rescue Exception => e
      error {
        msg = "Error in worker thread (shutting down) class=%s message=%s\n\t%s"
        sprintf(msg, e.class, e.message.dump, Array(e.backtrace).join("\n\t"))
      }
    ensure
      release_marker
    end

    def enqueue_msg(msg)
      queue = Thread.current.thread_variable_get(:send_queue)
      queue << msg
      # queue_byte_size = Thread.current.thread_variable_get(:send_queue_byte_size)
      # size = msg.to_json.bytesize + 1
      # Thread.current.thread_variable_set(:send_queue_byte_size, queue_byte_size + size)
    end

    def check_and_send
      queue = Thread.current.thread_variable_get(:send_queue)
      return if queue.empty?
      last_sent = Thread.current.thread_variable_get(:last_sent)
      if queue.length >= MAX_EVENTS || (Time.now.to_i - last_sent.to_i) >= SEND_TIMEOUT
        send_now(queue)
        queue.clear
      end
    end

    def work(msg)
      enqueue_msg(msg)
      check_and_send

      if shutdown? && throttled?
        warn { sprintf('Unable to report %s error(s) to Honeybadger (currently throttled)', queue.size) } if queue.size > 1
        kill!
        return
      end

      sleep(throttle_interval)
    rescue StandardError => e
      error {
        msg = "Error in worker thread class=%s message=%s\n\t%s"
        sprintf(msg, e.class, e.message.dump, Array(e.backtrace).join("\n\t"))
      }
    end

    def send_to_backend(msg)
      d { 'events_worker sending to backend' }
      events_backend.send_event(msg)
    end

    def calc_throttle_interval
      ((BASE_THROTTLE ** throttle) - 1).round(3)
    end

    def inc_throttle
      mutex.synchronize do
        @throttle += 1
        @throttle_interval = calc_throttle_interval
        throttle
      end
    end

    def dec_throttle
      mutex.synchronize do
        return nil if throttle == 0
        @throttle -= 1
        @throttle_interval = calc_throttle_interval
        throttle
      end
    end

    def handle_response(msg, response)
      d { sprintf('events_worker response code=%s message=%s', response.code, response.message.to_s.dump) }

      case response.code
      when 429, 503
        throttle = inc_throttle
        warn { sprintf('Event send failed: project is sending too many errors. id=%s code=%s throttle=%s interval=%s', msg.id, response.code, throttle, throttle_interval) }
      when 402
        warn { sprintf('Event send failed: payment is required. id=%s code=%s', msg.id, response.code) }
        suspend(3600)
      when 403
        warn { sprintf('Event send failed: API key is invalid. id=%s code=%s', msg.id, response.code) }
        suspend(3600)
      when 413
        warn { sprintf('Event send failed: Payload is too large. id=%s code=%s', msg.id, response.code) }
      when 201
        if throttle = dec_throttle
          info { sprintf('Success ⚡ Event sent code=%s throttle=%s interval=%s', response.code, throttle, throttle_interval) }
        else
          info { sprintf('Success ⚡ Event sent code=%s', response.code) }
        end
      when :stubbed
        info { sprintf('Success ⚡ Development mode is enabled; This event will be sent after app is deployed.') }
      when :error
        warn { sprintf('Event send failed: an unknown error occurred. code=%s error=%s', response.code, response.message.to_s.dump) }
      else
        warn { sprintf('Event send failed: unknown response from server. code=%s', response.code) }
      end
    end

    # Release the marker. Important to perform during cleanup when shutting
    # down, otherwise it could end up waiting indefinitely.
    def release_marker
      signal_marker(marker)
    end

    def signal_marker(marker)
      mutex.synchronize do
        marker.signal
      end
    end
  end
end
