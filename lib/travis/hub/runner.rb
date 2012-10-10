require 'multi_json'
require 'benchmark'
require 'active_support/core_ext/float/rounding'
require 'core_ext/kernel/run_periodically'
require 'core_ext/hash/compact'

require 'travis'
require 'travis/support'

require 'travis/hub/handler'
require 'travis/hub/error'
require 'travis/hub/queues'

$stdout.sync = true


module Travis
  module Hub
    class Runner

      class << self
        def start
          hub = self.new
          hub.start
        end
      end

      def start
        setup
        prune_workers
        enqueue_jobs
        Travis::Hub::Queues.subscribe
      end

      protected

        def setup
          Travis::Async.enabled = true
          Travis::Amqp.config = Travis.config.amqp
          Travis.services = Travis::Services
          GH::DefaultStack.options[:ssl] = Travis.config.ssl

          Travis.config.update_periodically
          Travis::Memory.new(:hub).report_periodically if Travis.env == 'production'

          Travis::Exceptions::Reporter.start
          Travis::Notification.setup

          Travis::Database.connect
          Travis::Mailer.setup
          Travis::Features.start

          NewRelic.start if File.exists?('config/newrelic.yml')
        end

        def prune_workers
          run_periodically(Travis.config.workers.prune.interval, &::Worker.method(:prune))
        end

        def enqueue_jobs
          run_periodically(Travis.config.queue.interval) { Job::Queueing::All.new.run }
        end

        # def cleanup_jobs
        #   run_periodically(Travis.config.jobs.retry.interval, &::Job.method(:cleanup))
        # end
    end
  end
end