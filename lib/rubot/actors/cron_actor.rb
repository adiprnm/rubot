# frozen_string_literal: true

require_relative "../cron_scheduler"
require_relative "../cron_commands"
require_relative "../safety_guard"

module Rubot
  module Actors
    # Owns the cron scheduler and its job store inside a dedicated Ractor.
    #
    # Channels and session actors never touch the scheduler directly; they
    # send commands through #call and receive fired-job events on the
    # delivery port they supplied at construction time.
    class CronActor
      attr_reader :ractor

      # @param workspace [String, nil]
      # @param delivery [Ractor::Port, nil] receives [:cron_fire, payload]
      def initialize(workspace:, restrict_to_workspace: true, allow_read_outside: false, delivery: nil)
        @ractor = Ractor.new(
          {
            workspace: workspace,
            restrict_to_workspace: restrict_to_workspace,
            allow_read_outside: allow_read_outside,
            delivery: delivery
          },
          name: "rubot-cron"
        ) do |args|
          ws = args[:workspace]
          port = args[:delivery]

          guard = SafetyGuard.new(
            workspace: ws,
            restrict_to_workspace: args[:restrict_to_workspace],
            allow_read_outside: args[:allow_read_outside]
          )

          scheduler = CronScheduler.new(workspace: ws, safety_guard: guard) do |fire|
            port&.send([ :cron_fire, fire ])
          end
          scheduler.start

          CronActor.serve(scheduler)
        end
      end

      # Runs inside the Ractor. Public class methods are shareable code.
      def self.serve(scheduler)
        loop do
          msg = Ractor.receive
          case msg[:type]
          when :command
            reply = begin
              [ :ok, CronActor.handle_command(scheduler, msg) ]
            rescue StandardError => e
              [ :error, "#{e.class}: #{e.message}" ]
            end
            msg[:port] << reply
          when :shutdown
            scheduler.stop
            break
          end
        end
      end

      def self.handle_command(scheduler, msg)
        operation = msg[:operation].to_s
        arguments = (msg[:arguments] || {}).merge("operation" => operation)

        if operation == "fire_due"
          scheduler.fire_due_jobs
        else
          CronCommands.execute(
            scheduler,
            arguments,
            delivery_context: msg[:delivery_context]
          )
        end
      end

      # Synchronous command call. Returns the command's result or raises.
      def call(operation:, arguments: {}, delivery_context: nil)
        port = Ractor::Port.new
        @ractor.send({
          type: :command,
          operation: operation,
          arguments: arguments,
          delivery_context: delivery_context,
          port: port
        })
        status, value = port.receive
        raise value if status == :error && value.is_a?(Exception)
        raise value.to_s if status == :error
        value
      ensure
        port&.close
      end

      # Fire due jobs now (used by inline/legacy processing paths).
      def fire_due
        call(operation: "fire_due")
      end

      def shutdown
        @ractor.send({ type: :shutdown })
        @ractor.join
      rescue Ractor::ClosedError, Ractor::RemoteError
        nil
      end
    end
  end
end
