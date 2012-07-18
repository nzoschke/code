module Code
  module Config
    def self.env(k, opts={})
      opts = { required: true }.merge(opts)

      unless v = ENV[k]
        v = opts[:default]
        abort("error: require #{k}") if opts[:required] && !v
      end

      v
    end
  end
end