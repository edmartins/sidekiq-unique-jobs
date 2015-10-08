require 'digest'
require 'sidekiq_unique_jobs/normalizer'

module SidekiqUniqueJobs
  # This class exists to be testable and the entire api should be considered private
  # rubocop:disable ClassLength
  class UniqueArgs
    extend Forwardable
    include Normalizer

    def_delegators :SidekiqUniqueJobs, :config, :worker_class_constantize
    def_delegators :'Sidekiq.logger', :logger, :debug, :warn, :error, :fatal

    def self.digest(item)
      new(item).unique_digest
    end

    def initialize(job)
      Sidekiq::Logging.with_context(self.class.name) do
        @item = job
        @worker_class ||= worker_class_constantize(@item[CLASS_KEY])
        @item[UNIQUE_PREFIX_KEY] ||= unique_prefix
        @item[UNIQUE_ARGS_KEY] ||= unique_args(@item[ARGS_KEY])
        @item[UNIQUE_DIGEST_KEY] ||= unique_digest
      end
    end

    def unique_digest
      @unique_digest ||= begin
        digest = Digest::MD5.hexdigest(Sidekiq.dump_json(digestable_hash))
        digest = "#{unique_prefix}:#{digest}"
        debug { "#{__method__} : #{digestable_hash} into #{digest}" }
        digest
      end
    end

    def unique_prefix
      return config.unique_prefix unless sidekiq_worker_class?
      @worker_class.get_sidekiq_options[UNIQUE_PREFIX_KEY] || config.unique_prefix
    end

    def digestable_hash
      hash = @item.slice(CLASS_KEY, QUEUE_KEY, UNIQUE_ARGS_KEY)

      if unique_on_all_queues?
        debug { "uniqueness specified across all queues (deleting queue: #{@item[QUEUE_KEY]} from hash)" }
        hash.delete(QUEUE_KEY)
      end
      hash
    end

    def unique_args(args)
      if unique_args_enabled?
        filtered_args(args)
      else
        debug { "#{__method__} : unique arguments disabled" }
        args
      end
    rescue NameError
      # fallback to not filtering args when class can't be instantiated
      return args
    end

    def unique_on_all_queues?
      return unless sidekiq_worker_class?
      return unless unique_args_enabled?
      @worker_class.get_sidekiq_options[UNIQUE_ON_ALL_QUEUES_KEY]
    end

    def unique_args_enabled?
      unique_args_enabled_in_worker? ||
        config.unique_args_enabled
    end

    def unique_args_enabled_in_worker?
      return unless sidekiq_worker_class?
      @worker_class.get_sidekiq_options[UNIQUE_ARGS_ENABLED_KEY] ||
        @worker_class.get_sidekiq_options[UNIQUE_ARGS_KEY]
    end

    def sidekiq_worker_class?
      if @worker_class.respond_to?(:get_sidekiq_options)
        true
      else
        debug { "#{@worker_class} does not respond to :get_sidekiq_options" }
        nil
      end
    end

    # Filters unique arguments by proc or symbol
    # returns provided arguments for other configurations
    def filtered_args(args)
      return args if args.empty?
      json_args = Normalizer.jsonify(args)
      debug { "#filtered_args #{args} => #{json_args}" }

      case unique_args_method
      when Proc
        filter_by_proc(json_args)
      when Symbol
        filter_by_symbol(json_args)
      else
        debug { 'arguments not filtered (the combined arguments count towards uniqueness)' }
        json_args
      end
    end

    def filter_by_proc(args)
      filter_args = unique_args_method.call(args)
      debug { "#{__method__} : #{args} -> #{filter_args}" }
      filter_args
    end

    def filter_by_symbol(args)
      unless @worker_class.respond_to?(unique_args_method)
        warn do
          "#{__method__} : #{unique_args_method}) not defined in #{@worker_class} " \
               "returning #{args} unchanged"
        end
        return args
      end

      filter_args = @worker_class.send(unique_args_method, args)
      debug { "#{__method__} : #{unique_args_method}(#{args}) => #{filter_args}" }
      filter_args
    end

    def unique_args_method
      @unique_args_method ||=
        @worker_class.get_sidekiq_options[UNIQUE_ARGS_KEY] if sidekiq_worker_class?
    end
  end
end