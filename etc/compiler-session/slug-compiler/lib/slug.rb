require "fileutils"
require "thread"
require "uri"
require "cgi"
require "yaml"
require "net/http"
require "net/https"
require "iconv"
require "securerandom"

require "utils"
require "repo_lock"
require "buildpack"

class Slug
  attr_reader :compile_id, :repo_dir, :build_dir, :slug_file, :release_file, :meta, :head, :prev

  def initialize(options)
    @meta = options[:meta]
    @compile_id = SecureRandom.hex
    @repo_dir = options[:repo_dir].chomp("/")
    @input_tar = options[:input_tar]
    @head = resolve_ref(options[:head])
    @prev = resolve_ref(options[:prev])
    @build_dir = (options[:build_dir] || resolve_build_dir).chomp("/")
    @slug_file = options[:slug_file] || resolve_slug_file
    @release_file = options[:release_file]
  end

  def app_id; meta["id"]; end
  def slug_put_key; meta["slug_put_key"]; end
  def slug_put_url; meta["slug_put_url"]; end
  def requested_stack; meta["requested_stack"]; end
  def stack; meta["stack"]; end
  def env; meta["env"] || {}; end
  def current_seq; meta["current_seq"]; end
  def user_email; meta["user_email"]; end
  def release_descr; meta["release_descr"]; end
  def release_url; meta["release_url"]; end
  def slug_version; meta["requested_slug_version"]; end
  def commit_hash; meta["commit_hash"]; end
  def url; meta["url"]; end
  def heroku_log_token; meta["heroku_log_token"]; end
  def addons; meta["addons"] || []; end
  def addons_stacks; meta["addons_stacks"]; end
  def allow_procfile_bamboo; meta["allow_procfile_bamboo"]; end
  def ignore_slug_size; meta["ignore_slug_size"]; end
  def user_env_compile; meta["user_env_compile"]; end

  def feature_flags
    @feature_flags ||= meta["feature_flags"].split(",")
  end

  def message(text)
    Utils.message(text)
  end

  def resolve_slug_file
    "/tmp/slug_#{compile_id}.img"
  end

  def git(args)
    Utils.bash("cd #{repo_dir}; git #{args}") if File.exists?(repo_dir)
  end

  def resolve_ref(ref)
    (git("rev-parse #{ref}") || '0000000').chomp
  end

  def resolve_build_dir
    "/tmp/build_#{compile_id}"
  end

  def cache_dir_path
    if @input_tar
      dir = Dir.mktmpdir
      at_exit { FileUtils.remove_entry_secure(dir) }
      dir
    else
      File.join(repo_dir, ".cache")
    end
  end

  def buildpack_url
    env["BUILDPACK_URL"] || env["LANGUAGE_PACK_URL"]
  end

  def buildpack_dir
    "/tmp/buildpack_#{compile_id}"
  end

  def user_env
    user_env_compile ? env : {}
  end

  class CompileError < RuntimeError; end

  def compile
    log("compile") do
      Utils.timeout(20*60) do
        message_receive
        message_stack_migration
        check_empty
        prepare_build_dir
        prune_build_dir
        process_slugignore
        configure_environment
        fetch_buildpacks
        detect_buildpack
        message_buildpack
        run_buildpack
        block_non_cedar_procfile
        message_procfile
        adjust_permissions
        make_binary_directory_executable
        write_release
      end
    end
  end

  def archive
    log("archive") do
      create_squashfs_volume
      check_sizes
    end
  end

  def message_receive
    log("message_receive")
    message "\n"
    message "-----> Heroku receiving push\n"
  end

  def migrating_stacks?
    requested_stack && (requested_stack != stack)
  end

  def stack_manifest
    {"aspen" => "Rails or Rack",
     "bamboo" => "Rails or Rack",
     "cedar" => "Cedar-supported"}
  end

  def message_buildpack
    log("message_buildpack") do
      if @pack_inst
        message "-----> #{@pack_inst.name} app detected\n"
      else
        raise(CompileError, "no #{stack_manifest[major_stack]} app detected")
      end
    end
  end

  def cedar_buildpack_classes
    [
      BuildPack::Ruby,
      BuildPack::NodeJS,
      BuildPack::Clojure,
      BuildPack::Python,
      BuildPack::Java,
      BuildPack::Gradle,
      BuildPack::Grails,
      BuildPack::Scala,
      BuildPack::Play,
      BuildPack::PHP,
    ]
  end

  def buildpacks(classes)
    classes.map { |klass| klass.new(build_dir, cache_dir_path, user_env) }
  end

  def fetch_buildpacks
    if buildpack_url
      fetch_buildpack(buildpack_url)
    else
      ["ruby", "nodejs", "clojure", "python", "java", "gradle", "grails", "scala", "play", "php"].each do |name|
        bucket = ENV["BUILDPACK_BUCKET"] || "codon-buildpacks"
        url = "http://#{bucket}.s3.amazonaws.com/buildpacks/heroku/#{name}.tgz"
        fetch_buildpack(url)
      end
    end
  end

  def fetch_buildpack(buildpack_url)
    log("fetch_buildpack") do
      Utils.clear_var("GIT_DIR") do
        uri  = URI.parse(buildpack_url)
        name = uri.path.split("/")[-1].split(".")[0]
        dir  = "#{buildpack_dir}/#{name}"
        Utils.bash("mkdir -p #{dir}")
        if buildpack_url =~ /\.(tgz|tar\.gz)$/
          message("-----> Fetching custom tar buildpack (#{name})... ")
          curl_opts = [["max-time", 90], ["url", buildpack_url], ["silent"], ["retry", 3]]
          command = "curl --config %s | tar xz -C #{dir}"
          exit_status, out = Utils.with_conf(curl_opts) { |path| Utils.bash(command % path) }
        else
          begin
            message("-----> Fetching custom git buildpack... ")
            url, treeish = buildpack_url.split("#")
            Utils.bash("cd #{dir}; git clone '#{url}' .", 10)
            Utils.bash("cd #{dir}; git checkout #{treeish}") if treeish
          rescue => e
            message("failed\n")
            raise(CompileError, "error fetching custom buildpack")
          end
        end
        message("done\n")
      end
    end
  end

  def detect_buildpack
    log("detect_buildpack") do
      packs = []

      if cedar? and buildpack_url
        packs = [BuildPack::Custom.new(buildpack_dir, build_dir, cache_dir_path, user_env)]
      elsif cedar? and feature_flags.detect {|f| f == "buildpacks-default" }
        # The list of default buildpacks is also specified in codon's
        # lib/receiver.rb; need to keep them in sync.
        defaults = ["ruby", "nodejs", "clojure", "python", "java", "gradle",
                    "grails", "scala", "play", "php"]
        paths = defaults.map {|d| File.join(buildpack_dir, d)}
        packs = paths.map {|path| BuildPack::Custom.new(path, build_dir, cache_dir_path, user_env)}
      elsif cedar?
        packs = buildpacks(cedar_buildpack_classes)
      else
        bamboo_buildpack_dir = buildpack_url ? buildpack_dir : File.join(File.dirname(__FILE__), "..", "buildpacks", "ruby_bamboo")
        require File.join(bamboo_buildpack_dir, "lib", "ruby_bamboo")

        RubyBamboo.load
        bamboo_inst = RubyBamboo.new(
          :build_dir => self.build_dir,
          :repo_dir => self.repo_dir,
          :requested_stack => self.requested_stack,
          :head => self.head,
          :prev => self.prev,
          :stack => self.stack,
          :env => self.env,
          :heroku_log_token => self.heroku_log_token,
          :addons => self.addons,
          :addons_stacks => self.addons_stacks)
        logo_inst = BuildPack::Logo.new(build_dir, cache_dir_path)
        packs = [bamboo_inst, logo_inst]
      end

      pack = packs.detect { |p| p.use? }

      # no buildpack detected, log all detect output
      if !pack
        packs.each do |p|
          exit_status, out = p.detect
          out = out.split("\n").join(" ")
          log("detect_buildpack at=error pack=#{p.class} exit_status=#{exit_status} out='#{out}'")
        end
      end
      @pack_inst = pack
    end
  end

  def create_squashfs_volume
    log("create_squashfs_volume") do
      Utils.bash("#{mksquashfs_bin} #{build_dir} #{slug_file} -all-root -noappend")
    end
  end

  def mksquashfs_bin
    return "/usr/bin/mksquashfs"  if File.exists?("/usr/bin/mksquashfs")
    return "/usr/sbin/mksquashfs" if File.exists?("/usr/sbin/mksquashfs")
    return "/usr/local/bin/mksquashfs" if File.exists?("/usr/local/bin/mksquashfs") # homebrew
    raise StandardError, "Can not find mksquashfs binary."
  end

  def checkout_build_dir_with_submodules
    log("checkout_build_dir_with_submodules")
    # clone the repo into the build dir so that submodule
    Utils.bash("cd #{File.dirname(build_dir)} && git clone #{repo_dir + "/"} #{build_dir}")

    # temporarily unset GIT_DIR so that we can operate in the build repo
    git_dir = ENV.delete("GIT_DIR")

    # checkout specified head and warn about or install submodules
    Utils.bash("cd #{build_dir}; git checkout #{head}")

    # if submodules are detected, attempt to install them via a spawned process
    # so that output is displayed to the user.
    # continue even if an error is encountered to avoid rejecting pushes that
    # would have not have been rejected before slugc supported git submoudles
    if File.exists?(File.join(build_dir, ".gitmodules"))
      submodules = File.read(File.join(build_dir, ".gitmodules")).split("\n")
      if !submodules.empty?
        start = Time.now
        message "-----> Git submodules detected, installing\n"
        exit_code = Utils.spawn("cd #{build_dir} && git submodule update --init --recursive", 300)
        if (exit_code != 0)
          message " !     Submodule install failed, continuing\n"
        end
        log("submodules_run exit_code=#{exit_code} elapsed=#{Time.now - start}")
      end
    end

    # reset GIT_DIR
    ENV["GIT_DIR"] = git_dir
  end

  def check_empty
    log("check_empty") do
      raise(CompileError, "cannot delete master branch") if (head == ("0"*40))
    end
  end

  def prepare_build_dir
    log("prepare_build_dir")
    Utils.bash("rm -rf #{build_dir}")

    if @input_tar
      untar_build_dir
    else
      checkout_build_dir
    end
  end

  def untar_build_dir
    log("untar_build_dir") do
      FileUtils.mkdir_p(build_dir)
      Utils.bash("cd #{build_dir} && tar xf #{@input_tar}")
    end
  end

  def checkout_build_dir
    log("checkout_build_dir") do
      checkout_build_dir_with_submodules

      # git writes the commit SHA to repo.git/HEAD on checkout. we need to
      # revert the HEAD commit back to master. not doing this can lead to
      # corrupt repositories when a push is rejected since the HEAD file points
      # to a commit that doesn't exist.
      File.open(File.join(repo_dir, "HEAD"), "w") do |f|
        f.write("ref: refs/heads/master\n")
      end
    end
  end

  def prune_build_dir
    log("prune_build_dir") do
      dirs =  %w[.git tmp log]
      dirs -= %w[tmp] if cedar? # Rails 3.1 needs tmp/cache preserved for pre-compiled assets
      dirs.each do |path|
        Utils.bash("rm -rf #{File.join(build_dir, path)}")
      end

      if !Utils.bash("find #{build_dir} -name .DS_Store").empty?
        message "-----> Removing .DS_Store files\n"
        Utils.bash("find #{build_dir} -name .DS_Store -print0 | xargs -0 rm")
      end

      raise(CompileError, "repository is empty.") if Dir.glob(File.join(build_dir, "*")).empty?
    end
  end

  def process_slugignore
    # general pattern format follows .gitignore:
    # http://www.kernel.org/pub/software/scm/git/docs/gitignore.html
    # blank => nothing; leading # => comment
    # everything else is more or less a shell glob
    slugignore_path = File.join(build_dir, ".slugignore")
    return if !File.exists?(slugignore_path)
    log("process_slugignore") do
      lines = File.read(slugignore_path).split
      lines.each do |line|
        line.strip!
        next if line.empty?
        next if line.match(/^#/) # comment

        # 1.8.7 and 1.9.2 handle expanding ** differently, where in 1.9.2 ** doesn't match the empty case. So try empty ** explicitly
        globs = ["", "**"].map { |g| File.join(build_dir, g, line) }
        to_delete = Dir[*globs].uniq.map { |p| File.expand_path(p) }.select { |p| p.match(/^#{build_dir}/) }
        to_delete.each { |p| FileUtils.rm_rf(p) }
      end
    end
  end

  def configure_environment
    return unless (slug_version == 1)
    log("configure_environment") do
      env['db'] = database_url_to_hash(env['DATABASE_URL']) if env['DATABASE_URL']
      File.open(File.join(build_dir, "heroku_env.yml"), "w") { |f| f.write(YAML.dump(env)) }
      Utils.bash("mkdir -p #{File.join(build_dir, "config")}")
      File.open(File.join(build_dir, "config", "database.yml"), "w") { |f| f.write(YAML.dump(env["RACK_ENV"] => env["db"])) }
    end
  end

  def database_url_to_hash(database_url)
    uri = URI.parse(database_url)
    adapter = uri.scheme
    adapter = 'postgresql' if adapter == 'postgres'
    config = {
      'adapter' => adapter,
      'database' => [nil, ''].include?(uri.path) ? uri.host : uri.path.split('/')[1],
      'username' => uri.user,
      'password' => uri.password,
      'host' => uri.host,
      'port' => uri.port,
    }
    if adapter == 'postgresql' && config['port'].nil?
      config['port'] = 5432
      config['encoding'] = 'unicode'
    end

    params = CGI.parse(uri.query || '')
    if params.has_key?('encoding')
      config['encoding'] = params['encoding'].first
    end

    config
  rescue URI::InvalidURIError
    raise(CompileError, "could not parse DATABASE_URL: #{database_url}")
  end

  def adjust_permissions
    log("adjust_permissions") do
      # Make the permissions for other users match the permissions for the
      # owner.  Because when the squashfs is mounted, root owns the files, but
      # the dynos run as the slug user.
      return if cedar?
      Utils.bash("find #{build_dir} -mindepth 1 -perm -u=r -not -type l -print0 | xargs -0 -r chmod g+r")
      Utils.bash("find #{build_dir} -mindepth 1 -perm -u=x -not -type l -print0 | xargs -0 -r chmod g+x")
    end
  end

  def make_binary_directory_executable
    if File.directory?(File.join(build_dir, "bin"))
      log("make_binary_directory_executable") do
        Utils.bash("chmod -R a+x #{File.join(build_dir, "bin")}")
      end
    end
  end

  def check_sizes
    log("check_sizes") do
      raw_size = Utils.bash("du -s -x #{build_dir}").split(" ").first.to_i*1024
      slug_size = File.size(slug_file)
      log("check_sizes at=emit raw_size=#{raw_size} slug_size=#{slug_size}")
      check_slug_size
    end
  end

  def max_slug_size
    200
  end

  def check_slug_size
    slug_size = File.size(slug_file) / 1024.0
    if slug_size < 1000
      message sprintf("-----> Compiled slug size is %1.0fK\n", slug_size)
    else
      slug_size /= 1024.0
      if slug_size > max_slug_size && !ignore_slug_size
        message "\n"
        message sprintf("-----> Push rejected, your compiled slug is %1.1fMB (max is #{max_slug_size}MB).\n", slug_size)
        message "       See: http://devcenter.heroku.com/articles/slug-size"
        raise CompileError, "slug too large"
      else
        message sprintf("-----> Compiled slug size is %1.1fMB\n", slug_size)
      end
    end
  end

  def run_buildpack
    log("run_buildpack") do
      @pack_inst.compile
    end
  end

  def lock
    if @input_tar
      yield self
    else
      RepoLock.new(app_id, repo_dir).run { yield self }
    end
  end

  def store_in_s3
    log("store_in_s3 at=start slug_size=#{File.size(slug_file)}"); start = Time.now
    curl_opts = [["max-time", 60], ["retry", 3], ["write-out", "%{http_code}"], ["data-binary", "@#{slug_file}"],
                 ["header", "Content-Type:"], ["request", "PUT"], ["url", slug_put_url], ["silent"]]
    out = Utils.with_conf(curl_opts) { |p| `curl --config #{p}` }
    raise("store_in_s3 at=error elapsed=#{Time.now - start} out='#{out}'") if (out != "200")
    log("store_in_s3 at=finish elapsed=#{Time.now - start} slug_size=#{File.size(slug_file)}")
  end

  def git_log
    if commit_hash && !commit_hash.empty?
      range = "#{commit_hash}..#{head}"
      log = Utils.bash("cd #{repo_dir} && git log --no-color --pretty=format:'  * %an: %s' --abbrev-commit --no-merges #{range} 2>/dev/null | head -c 10000") rescue ""

      # re-encode untrusted string
      begin
        ic = Iconv.new("UTF-8//IGNORE", "UTF-8")
        ic.iconv(log)
      rescue Iconv::InvalidCharacter => e
        ""
      end
    else
      ""
    end
  end

  def repo_size
    cmd = "du --exclude gems --exclude slugs -s #{repo_dir}"
    cmd = "du -d 0 #{repo_dir}" if `uname` =~ /Darwin/ # less accurate but fine for local specs
    Utils.bash(cmd).split.first.to_i * 1024
  end

  def write_release
    return if !release_file
    log("write_release") do
      File.open(release_file, "w") do |f|
        f.write(YAML.dump({
          "language_pack" => @pack_inst.name,
          "buildpack" => @pack_inst.name,
          "process_types" => process_types,
          "addons" => @pack_inst.addons,
          "config_vars" => @pack_inst.config_vars}))
      end
    end
  end

  def post_release(deploy_hooks)
    start = Time.now
    log("post_release at=start")
    payload = {
      "head" => head,
      "prev_head" => commit_hash,
      "current_seq" => current_seq,
      "slug_version" => slug_version,
      "repo_size" => repo_size,
      "slug_size" => File.size(slug_file),
      "language_pack" => @pack_inst.name,
      "buildpack" => @pack_inst.name,
      "stack" => target_stack,
      "user" => user_email,
      "release_descr" => release_descr,
      "process_types" => process_types,
      "slug_put_key" => slug_put_key,
      "git_log" => git_log,
      "run_deploy_hooks" => deploy_hooks,
      "addons" => @pack_inst.addons,
      "config_vars" => @pack_inst.config_vars}

    release_name =
      Utils.timeout(30) do
        uri = URI.parse(release_url)
        http = Net::HTTP.new(uri.host, uri.port)
        request = Net::HTTP::Post.new(uri.request_uri)
        if uri.scheme == "https"
          http.use_ssl = true
          http.verify_mode = OpenSSL::SSL::VERIFY_NONE
        end
        request.basic_auth(uri.user, uri.password)
        request["Content-Type"] = "text/yaml"
        request["Accept"] = "text/yaml"
        request.body = YAML.dump(payload)
        response = http.request(request)
        if (response.code != "200")
          raise("post_release at=error code='#{response.code}' body='#{response.body.strip}' elapsed=#{Time.now - start}")
        end
        response.body
      end
    log("post_release at=finish elapsed=#{Time.now - start}")
    release_name
  end

  def message_deploy_hooks
    return unless addons.any? { |a| a =~ /^(deployhooks|newrelic):/ || a =~ /_hook$/ }
    log("message_deploy_hooks")
    message("-----> Deploy hooks scheduled, check output in your logs\n")
  end

  def release(deploy_hooks)
    log("release") do
      message("-----> Launching...")
      store_in_s3
      release_name = post_release(deploy_hooks)
      message(" done, #{release_name}\n")
      message_deploy_hooks
      message("       http://#{url} deployed to Heroku\n\n")
      message_stack_migration_complete
    end
  end

  def target_stack
    requested_stack || stack
  end

  def major_stack
    target_stack.split("-")[0]
  end

  def is_stack?(s)
    major_stack == s.to_s
  end

  def cedar?
    is_stack?("cedar")
  end

  def message_stack_migration
    if migrating_stacks?
      log("message_stack_migration")
      message "-----> Migrating from #{stack} to #{requested_stack}\n"
      message "\n"
    end
  end

  def message_stack_migration_complete
    if migrating_stacks?
      log("message_stack_migration_complete")
      message "-----> Migration complete, your app is now running on #{requested_stack}\n"
      message "\n"
    end
  end

  def procfile_path
    File.join(build_dir, "Procfile")
  end

  def parse_procfile(txt)
    txt.split("\n").inject({}) do |ps, line|
      if m = line.match(/^([a-zA-Z0-9_]+):?\s+(.*)/)
        ps[m[1]] = m[2]
      end
      ps
    end
  end

  def check_malformed_procfile(txt)
    txt.split("\n").each do |line|
      if m = line.match(/^([a-zA-Z0-9_]+)\s+(.*)/)
        return [m[1], m[2]]
      end
    end
    false
  end

  def procfile_pstable
    parse_procfile(File.read(procfile_path))
  end

  def default_pstable
    @pack_inst.default_process_types
  end

  def process_types
    if File.exists?(procfile_path)
      default_pstable.merge(procfile_pstable)
    else
      default_pstable
    end
  end

  def block_non_cedar_procfile
    if !cedar? && File.exists?(procfile_path) && !allow_procfile_bamboo
      log("block_procfile")
      raise(CompileError, "Procfile is not supported on the #{major_stack.capitalize} stack")
    end
  end

  def message_procfile
    return unless (cedar? || allow_procfile_bamboo)
    log("message_procfile") do

      procfile_messages = []
      pack_name = @pack_inst.name

      message("-----> Discovering process types\n")

      if !File.exists?(procfile_path)
        log("no_procfile")
        procfile_messages << [ "Procfile declares types", ["(none)"] ]
        procfile_messages << [ "Default types for #{pack_name}", default_pstable.keys ]
      elsif malformed_ps = check_malformed_procfile(File.read(procfile_path))
        log("malformed_procfile")
        message("\n")
        message(" !     This format of Procfile is unsupported\n")
        message(" !     Use a colon to separate the process name from the command\n")
        message(" !     e.g.   #{malformed_ps[0]}:  #{malformed_ps[1]}\n")
        message("\n")
        raise(CompileError, "malformed Procfile")
      else
        log("valid_procfile")
        procfile_messages << [ "Procfile declares types", procfile_pstable.keys ]
        procfile_messages << [ "Default types for #{pack_name}", default_pstable.keys - procfile_pstable.keys ]
      end

      procfile_messages.reject! do |(text, types)|
        types.length == 0
      end

      longest_text = procfile_messages.map { |pm| pm.first.length }.sort.last

      procfile_messages.each do |(text, types)|
        message("       %-#{longest_text}s -> %s\n" % [ text, types.sort.join(", ") ])
      end
    end
  end

  def log_inflate(msg)
    "slug #{msg} app_id=#{app_id} compile_id=#{compile_id} slug_version=#{slug_version} major_stack=#{major_stack}"
  end

  def log(msg, &blk)
    Utils.log(log_inflate(msg), &blk)
  end

  def log_error(msg)
    Utils.log_error(log_inflate(msg))
  end

  def userlog(msg)
    Utils.userlog(heroku_log_token, msg)
  end
end
