require "openssl"
require "rack/streaming_proxy"
require "sinatra"

module Code
  module API
    class Proxy < Sinatra::Application
      AES_KEY, AES_IV = Config.env("AES_KEY_IV").split(":")
      COMPILER_API_URL        = Config.env("COMPILER_API_URL")
      COMPILER_API_KEY        = URI.parse(COMPILER_API_URL).password
      COMPILER_REPLY_TIMEOUT  = Config.env("COMPILER_REPLY_TIMEOUT", default: 30)
      REDIS_URL               = Config.env("REDIS_URL")
      S3_BUCKET               = Config.env("S3_BUCKET")

      helpers do
        def encrypt(data, key, iv, opts={})
          c = OpenSSL::Cipher::AES.new(128, :CBC)
          c.encrypt

          if opts[:decrypt]
            c.decrypt
            data = [data].pack("H*")
          end

          c.key = [key].pack("H*")
          c.iv  = [iv].pack("H*")

          t = c.update(data) + c.final
          opts[:decrypt] ? t : t.unpack("H*")[0]
        end

        def proxy!(hostname, port=80, username=nil, password=nil)
          req  = Rack::Request.new(env)
          auth = [username, password].join(":")
          uri  = "#{env["rack.url_scheme"]}://#{auth}@#{hostname}:#{port}"
          uri += env["PATH_INFO"]
          uri += "?" + env["QUERY_STRING"] unless env["QUERY_STRING"].empty?

          begin # only want to catch proxy errors, not app errors
            proxy = Rack::StreamingProxy::ProxyRequest.new(req, uri)
            [proxy.status, proxy.headers, proxy]
          rescue => e
            msg = "Proxy error when proxying to #{uri}: #{e.class}: #{e.message}"
            env["rack.errors"].puts msg
            env["rack.errors"].puts e.backtrace.map { |l| "\t" + l }
            env["rack.errors"].flush
            raise StandardError, msg
          end
        end

        def redis
          @redis ||= Redis.new(:url => REDIS_URL)
        end
      end

      get "/" do
        "hello proxy"
      end

      get "/:app_name.git/info/refs" do
        @app_name = params["app_name"]
        throw(:halt, [404, "Not found\n"]) unless @app_name =~ /^[a-z][a-z0-9-]+$/
        #throw(:halt, [404, "Not found\n"]) unless ACLS[@fingerprint].include?(@app_name)

        xid       = encrypt(@app_name, AES_KEY, AES_IV)
        key       = "compiler.session.#{xid}"
        reply_key = "#{key}.reply"

        redis.set     key, request.ip
        redis.expire  key, COMPILER_REPLY_TIMEOUT

        # fork http-compiler process
        # can be securely implemented via a `heroku run` API call
        env = {
          "BUILD_CALLBACK_URL"  => "",
          "BUILD_PUT_URL"       => "",
          "CALLBACK_URL"        => "http://localhost:5000/session/#{xid}",
        }

        ENV["S3_SRC"] = ENV["S3_DEST"] = "#{S3_BUCKET}/caches/#{@app_name}.tgz"
        env.merge!({
          "CACHE_GET_URL" => %x[bin/s3 get --url].strip,
          "CACHE_PUT_URL" => %x[bin/s3 put --url --ttl=3600].strip,
        })

        ENV["S3_SRC"] = ENV["S3_DEST"] = "#{S3_BUCKET}/repos/#{@app_name}.bundle"
        env.merge!({
          "REPO_GET_URL" => %x[bin/s3 get --url].strip,
          "REPO_PUT_URL" => %x[bin/s3 put --url --ttl=3600].strip,
        })

        # runtime environment
        env.merge!({
          "PATH"        => ENV["PATH"],
          "PORT"        => (6000 + rand(100)).to_s,
          "VIRTUAL_ENV" => ENV["VIRTUAL_ENV"]
        })

        pid = Process.spawn(env, "bin/http-compiler", unsetenv_others: true)

        # wait for compiler callback
        k, v = redis.brpop reply_key, COMPILER_REPLY_TIMEOUT
        if v
          data      = JSON.parse(v)
          hostname  = data["hostname"]
          port      = data["port"]
          username  = data["username"]

          proxy!(hostname, port, username)
        else
          status 503
          "No compiler available\n"
        end
      end

      post "/:app_name.git/git-receive-pack" do
        @app_name = params["app_name"]
        throw(:halt, [404, "Not found\n"]) unless @app_name =~ /^[a-z][a-z0-9-]+$/

        xid       = encrypt(@app_name, AES_KEY, AES_IV)
        key       = "compiler.session.#{xid}"
        reply_key = "#{key}.reply"

        # wait for compiler callback
        k, v = redis.brpop reply_key, COMPILER_REPLY_TIMEOUT
        if v
          data      = JSON.parse(v)
          hostname  = data["hostname"]
          port      = data["port"]
          username  = data["username"]

          proxy!(hostname, port, username)
        else
          status 503
          "No compiler available\n"
        end
      end

      post "/:app_name.git/git-upload-pack" do
        @app_name = params["app_name"]
        throw(:halt, [404, "Not found\n"]) unless @app_name =~ /^[a-z][a-z0-9-]+$/

        xid       = encrypt(@app_name, AES_KEY, AES_IV)
        key       = "compiler.session.#{xid}"
        reply_key = "#{key}.reply"

        # wait for compiler callback
        k, v = redis.brpop reply_key, COMPILER_REPLY_TIMEOUT
        if v
          data      = JSON.parse(v)
          hostname  = data["hostname"]
          port      = data["port"]
          username  = data["username"]

          proxy!(hostname, port, username)
        else
          status 503
          "No compiler available\n"
        end
      end

      put "/session/:xid" do
        @xid = params["xid"]

        key       = "compiler.session.#{@xid}"
        reply_key = "#{key}.reply"

        throw(:halt, [404, "Not found\n"]) unless redis.exists(key)

        data = params.select { |k, v| ["hostname", "port", "username"].include?(k) }
        redis.rpush   reply_key, JSON.dump(data)
        redis.expire  reply_key, COMPILER_REPLY_TIMEOUT
      end

      delete "/session/:xid" do
        @xid = params["xid"]

        key       = "compiler.session.#{@xid}"
        reply_key = "#{key}.reply"

        redis.del key, reply_key
      end

    end
  end
end