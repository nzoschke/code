require "open-uri"
require "fileutils"

module BuildPack
  class Base
    attr_reader :build_dir, :cache_dir, :env

    def initialize(build_dir, cache_dir, env={})
      @build_dir = build_dir
      @cache_dir = cache_dir
      @env = env
    end

    def bin_dir
      dirs = ["buildpacks", "language_packs"].map { |d| File.join(File.dirname(__FILE__), "..", d, root_dir, "bin") }
      dirs.detect { |d| File.exists? d }
    end

    def detect
      @detect ||= begin
        out = `#{File.join(bin_dir, "detect")} #{build_dir} 2>&1`
        exit_status = $?.exitstatus
        [exit_status, out]
      end
    end

    def use?
      detect[0] == 0
    end

    def name
      detect[1].chomp
    end

    def compile
      fork do
        @env.each { |k,v| ENV[k] = v.to_s }
        retval = Utils.spawn("#{File.join(bin_dir, "compile")} #{build_dir} #{cache_dir}", false)
        exit retval
      end
      Process.wait
      raise(Slug::CompileError, "failed to compile #{name.capitalize} app") if ($?.exitstatus != 0)
    end

    def release
      return @release if @release
      read, write = IO.pipe

      fork do
        read.close
        @env.each { |k,v| ENV[k] = v.to_s }
        write.puts Utils.bash("#{File.join(bin_dir, "release")} #{build_dir}")
        exit
      end

      write.close
      Process.wait
      @release = YAML.load(read.read)
      read.close

      @release
    end

    def config_vars
      release["config_vars"] || {}
    end

    def addons
      release["addons"] || {}
    end

    def default_process_types
      release["default_process_types"] || {}
    end
  end

  class Logo      < Base; def root_dir; "logo";       end; end
  class Clojure   < Base; def root_dir; "clojure";    end; end
  class NodeJS    < Base; def root_dir; "nodejs";     end; end
  class Python    < Base; def root_dir; "python";     end; end
  class Ruby      < Base; def root_dir; "ruby";       end; end
  class Java      < Base; def root_dir; "java";       end; end
  class Gradle    < Base; def root_dir; "gradle";     end; end
  class Grails    < Base; def root_dir; "grails";     end; end
  class Scala     < Base; def root_dir; "scala";      end; end
  class Play      < Base; def root_dir; "play";       end; end
  class PHP       < Base; def root_dir; "php";        end; end

  class Custom < Base
    def initialize(bp_dir, build_dir, cache_dir, env={})
      @bp_dir = bp_dir
      @build_dir = build_dir
      @cache_dir = cache_dir
      @env = env
    end

    def bin_dir
      File.join(@bp_dir, "bin")
    end
  end
end

module LanguagePack
  include BuildPack
end
