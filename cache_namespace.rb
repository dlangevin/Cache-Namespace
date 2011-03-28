=begin rdoc
  Methods to generate and reset unique keys for a given model
=end
module Lifebooker::Behaviors::CacheNamespace
  
  def self.included(klass)
    klass.class_inheritable_accessor(:cached_methods)
    klass.cached_methods = []
    klass.send(:include, InstanceMethods)
    klass.send(:extend, ClassMethods)
  end
  
  module ClassMethods
    # implementation of method_added, call alias_method_chain if appropriate
    def method_added(name)
      self.cached_methods ||= []
      # prevent an infinite loop from alias_method_chain by looking for x_without_caching
      if self.cached_methods.include?(name) && (self.instance_methods.blank? || !self.instance_methods.include?("#{name}_without_caching".to_sym))
        self.alias_method_chain(name, :caching)
      end
    end
    # class method to wrap a method in cache and memoize it
    def caches_method(name, opts = {})
      self.cached_methods << name.to_sym
      # add methods to uncache data during callbacks
      self.add_uncache_methods(name, opts)

      # add the aliased method _with_caching to handle storing the data
      define_method("#{name}_with_caching") do |*args|
        namespace_args = [name] + args
        # check a local instance variable
        unless cache = instance_variable_get(self.ivar_name(*namespace_args))
          # check our cache store
          cache = Rails.cache.fetch(self.current_namespace(*namespace_args), opts) do
            self.send("#{name}_without_caching", *args)
          end
          # and set an instance variable for later use
          instance_variable_set(self.ivar_name(*namespace_args), cache)
        end
        cache
      end
    end
    protected
    # add methods to uncache
    def add_uncache_methods(name, opts)
      # check to see if we have any callbacks
      if callbacks = opts.delete(:uncache_on)
        [*callbacks].each do |callback|
          self.send(callback, Proc.new{|record|
            record.send(:increment_namespace!, name)
          })
        end
      end
    end
  end
  
  module InstanceMethods
    # Get a namespace key including the current namespace key
    # e.g. ServiceProviderService-1122-1
    def current_namespace(*args)
      @current_namespaces ||= {}
      @current_namespaces[namespace_key(*args)] ||= "#{namespace_key(*args)}__#{Rails.cache.read(namespace_key(args.first)) || increment_namespace!(args.first)}"
    end
    
    # reset all namespaces for this model
    def uncache_all
      self.increment_namespace!
      self.class.cached_methods.each do |m|
        self.increment_namespace!(m)
      end
    end
    
    # helper method to get the ivar name for a given method/argument combo
    def ivar_name(*args)
      "@#{self.current_namespace(*args)}"
    end

    # Add one to the current namespace for this model
    def increment_namespace!(*args)
      # unset local cache of current_namespaces
      @current_namespaces = {}
      # add 1 to the value in cache
      val = (Rails.cache.read(namespace_key(args.first)) || 0) + 1
      Rails.cache.write(namespace_key(args.first),val)
      val
    end
    alias_method :uncache, :increment_namespace!
  
    # Unique identifier for a model's namespace
    # Defaults to ModelName-primary_key
    def namespace_key(key = nil, *args)
      key = key ? "__#{key}__#{args.hash}" : ""
      "#{self.class.to_s.underscore}__#{self.id.to_i}#{key}"
    end

    # Accessor to inspect if this instance is cacheable
    # Defaults to true, must be implemented in the subclass to enforce
    # cache-breaking
    def is_cacheable?
      true
    end
  end
end
