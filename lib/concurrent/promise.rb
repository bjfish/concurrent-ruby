require 'thread'

require 'concurrent/global_thread_pool'
require 'concurrent/obligation'

module Concurrent

  class Promise
    include Obligation
    include UsesGlobalThreadPool

    # Creates a new promise object. "A promise represents the eventual
    # value returned from the single completion of an operation."
    # Promises can be chained in a tree structure where each promise
    # has zero or more children. Promises are resolved asynchronously
    # in the order they are added to the tree. Parents are guaranteed
    # to be resolved before their children. The result of each promise
    # is passed to each of its children upon resolution. When
    # a promise is rejected all its children will be summarily rejected.
    # A promise that is neither resolved or rejected is pending.
    #
    # @param args [Array] zero or more arguments for the block
    # @param block [Proc] the block to call when attempting fulfillment
    #
    # @see http://wiki.commonjs.org/wiki/Promises/A
    # @see http://promises-aplus.github.io/promises-spec/
    def initialize(options = {}, &block)
      @parent = options.fetch(:parent) { nil }
      @on_fulfil = options.fetch(:on_fulfill) { Proc.new{ |result| result } }
      @on_reject = options.fetch(:on_reject) { Proc.new{ |result| result } }

      @lock = Mutex.new
      @handler = block || Proc.new{|result| result }
      @state = :unscheduled
      @rescued = false
      @children = []

      init_obligation
    end

    def self.fulfil(value)
      Promise.new.tap { |p| p.send(:set_state!, true, value, nil) }
    end

    def self.reject(reason)
      Promise.new.tap { |p| p.send(:set_state!, false, nil, reason) }
    end

    # @return [Promise]
    def execute
      if root?
        if compare_and_set_state(:pending, :unscheduled)
          set_pending
          realize(@handler)
        end
      else
        parent.execute
      end
      self
    end

    def self.execute(&block)
      new(&block).execute
    end


    # @return [Promise] the new promise
    def then(rescuer = nil, &block)
      raise ArgumentError.new('rescuers and block are both missing') if rescuer.nil? && !block_given?
      block = Proc.new{ |result| result } if block.nil?
      child = Promise.new(parent: self, on_fulfill: block, on_reject: rescuer)

      @lock.synchronize do
        child.state = :pending if @state == :pending
        @children << child
      end

      child
    end

    # @return [Promise]
    def on_success(&block)
      raise ArgumentError.new('no block given') unless block_given?
      self.then &block
    end


    # @return [Promise]
    def rescue(rescuer)
      self.then(rescuer)
    end
    alias_method :catch, :rescue
    alias_method :on_error, :rescue

    protected

    attr_reader :parent
    attr_reader :handler
    attr_reader :rescuers

    def set_pending
      self.state = :pending
      @children.each { |c| c.set_pending }
    end

    # @private
    def root? # :nodoc:
      @parent.nil?
    end

    # @private
    def on_fulfill(result)
      realize Proc.new{ @on_fulfil.call(result) }
      nil
    end

    # @private
    def on_reject(reason)
      realize Proc.new{ @on_reject.call(reason) }
      nil
    end

    def notify_child(child)
      if_state(:fulfilled) { child.on_fulfill(apply_deref_options(@value)) }
      if_state(:rejected) { child.on_fulfill(reason) }
    end

    # @private
    def realize(task)
      Promise.thread_pool.post do
        success, value, reason = SafeTaskExecutor.new( task ).execute
        set_state!(success, value, reason)
        @children.each{ |child| notify_child(child) }
      end
    end

    def set_state!(success, value, reason)
      mutex.synchronize do
        set_state(success, value, reason)
        event.set
      end
    end

  end
end
