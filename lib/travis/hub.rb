require 'multi_json'
require 'hashr'
require 'benchmark'
require 'hubble'
require 'metriks'
require 'metriks/reporter/logger'
require 'active_support/core_ext/float/rounding.rb'
require 'core_ext/module/include'
require 'core_ext/kernel/run_periodically'

require 'travis'
require 'travis/support'

# Order of inclusion matters: async must be included last
require 'travis/hub/instrumentation'
require 'travis/hub/async'

$stdout.sync = true

module Travis
  class Hub
    autoload :Handler,       'travis/hub/handler'
    autoload :Error,         'travis/hub/error'
    autoload :ErrorReporter, 'travis/hub/error_reporter'
    autoload :NewRelic,      'travis/hub/new_relic'

    include Logging

    class << self
      def start
        setup
        prune_workers
        new.subscribe
      end

      protected

        def setup
          Travis.config.update_periodically

          # TODO ask @rkh about this :)
          GH::DefaultStack.options[:ssl] = {
            :ca_path => Travis.config.ssl.ca_file,
            :ca_file => Travis.config.ssl.ca_file
          }

          start_monitoring
          Database.connect
          Travis::Mailer.setup
          Travis::Features.start
          Travis::Amqp.config = Travis.config.amqp
        end

        def start_monitoring
          Hubble.setup if ENV['HUBBLE_ENV']
          Travis::Hub::ErrorReporter.new.run
          Metriks::Reporter::Logger.new.start
          NewRelic.start if File.exists?('config/newrelic.yml')
        end

        def prune_workers
          run_periodically(Travis.config.workers.prune.interval, &::Worker.method(:prune))
        end

        def cleanup_jobs
          run_periodically(Travis.config.jobs.retry.interval, &::Job.method(:cleanup))
        end
    end

    include do
      def subscribe
        info 'Subscribing to amqp ...'

        subscribe_to_build_requests_and_configure_builds
        subscribe_to_reporting
        subscribe_to_worker_status
      end

      def subscribe_to_build_requests_and_configure_builds
        # TODO remove the reporting queue once workers have stopped picking up configure jobs
        ['builds.requests', 'builds.configure', 'reporting.jobs.builds.configure'].each do |queue|
          info "Subscribing to #{queue}"
          Travis::Amqp::Consumer.new(queue).subscribe(:ack => true, &method(:receive))
        end
      end

      def subscribe_to_reporting
        queue_names  = ['builds.common']
        queue_names += Travis.config.queues.map { |queue| queue[:queue] }

        queue_names.uniq.each do |name|
          info "Subscribing to #{name}"
          Travis::Amqp::Consumer.jobs(name).subscribe(:ack => true, &method(:receive))
        end
      end

      def subscribe_to_worker_status
        Travis::Amqp::Consumer.workers.subscribe(:ack => true, &method(:receive))
      end

      def receive(message, payload)
        event = message.properties.type
        debug "[#{Thread.current.object_id}] Handling event #{event.inspect} with payload : #{(payload.size > 160 ? "#{payload[0..160]} ..." : payload)}"

        with(:benchmarking, :caching) do
          if payload = decode(payload)
            handler = Handler.for(event, payload)
            handler.handle
          end
        end

        message.ack
      rescue Exception => e
        puts e.message, e.backtrace
        message.ack
        notify_error(Hub::Error.new(event, payload, e))
      end

      protected

        def with(*methods, &block)
          if methods.size > 1
            head = methods.shift
            with(*methods) { send(head, &block) }
          else
            send(methods.first, &block)
          end
        end

        def benchmarking(&block)
          timing = Benchmark.realtime(&block)
          debug "[#{Thread.current.object_id}] Completed in #{timing.round(4)} seconds"
        end

        def caching(&block)
          defined?(ActiveRecord) ? ActiveRecord::Base.cache(&block) : block.call
        end

        def decode(payload)
          MultiJson.decode(payload)
        rescue StandardError => e
          error "[#{Thread.current.object_id}] [decode error] payload could not be decoded with engine #{MultiJson.engine.to_s} : #{e.inspect}"
          nil
        end

        def notify_error(exception)
          Travis::Hub::ErrorReporter.enqueue(exception)
        end
    end
  end
end
