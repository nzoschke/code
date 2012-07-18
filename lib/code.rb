require "erb"
require "ostruct"
require "tmpdir"

STDOUT.sync = true

module Code
  def self.create_session_dir(template_dir, settings={})
    session_dir = Dir.mktmpdir

    settings["session_dir"] = session_dir
    b = OpenStruct.new(settings).instance_eval { binding } # ugh

    Dir.entries(template_dir).each do |l|
      next if [".", ".."].include?(l)

      conf = ""
      src  = File.join(template_dir, l)
      dest = File.join(session_dir,  l)

      File.open(src, "r") do |f|
        conf = f.read
        conf = ERB.new(conf).result(b) if src =~ /\.conf$/
      end

      File.open(dest, "w") do |f|
        f.write(conf)
        f.chmod(0700) if src =~ /\.sh$/
      end
    end

    session_dir
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