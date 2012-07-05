STDOUT.sync = true

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

class String
  # Strip leading whitespace from each line that is the same as the 
  # amount of whitespace on the first line of the string.
  # Leaves _additional_ indentation on later lines intact.
  def unindent
    gsub /^#{self[/\A\s*/]}/, ''
  end
end