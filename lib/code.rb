STDOUT.sync = true

module Code
  def self.env(k, required=true)
    ENV[k] || abort("require #{k}")
  end
end