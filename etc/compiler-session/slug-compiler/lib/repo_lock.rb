class RepoLock
  attr_reader :repo_dir, :app_id

  def initialize(app_id, repo_dir)
    @app_id = app_id
    @repo_dir = repo_dir
    @fp = nil
    log("initialize")
  end

  def lock_path
    File.join(repo_dir, "slugc_lock")
  end

  def aquire
    log("aquire at=start")
    if !File.exists?(repo_dir)
      log("aquire at=missing")
      raise("aquire at=missing")
    end
    @fp = File.open(lock_path, "w")
    ret = @fp.flock(File::LOCK_EX | File::LOCK_NB)
    if !(ret == 0)
      log("aquire at=locked ret=#{ret}")
      raise(Slug::CompileError, "slug is currently being compiled by another push")
    end
    log("aquire at=succeed")
  end

  def release
    log("release at=start")
    if @fp
      @fp.flock(File::LOCK_UN)
      @fp.close
      @fp = nil
    end
    log("release at=succeed")
  end

  def run(opts={}, &block)
    log("run at=start")
    begin
      aquire
      block.call
      log("run at=succeed")
    ensure
      log("run at=ensure")
      release
    end
    log("run at=finish")
  end

  def log(msg)
    Utils.log("repo_lock #{msg} app_id=#{app_id}")
  end
end
