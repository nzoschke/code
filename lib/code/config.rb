module Code
  module Config
    def self.env(k, opts={})
      if v = ENV[k]
        return v
      end

      abort("error: require #{k}") unless opts.has_key? :default

      opts[:default]
    end
  end
end