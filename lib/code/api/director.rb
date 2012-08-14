require "cgi"
require "heroku-api"
require "json"
require "net/ssh"
require "openssl"
require "redis"
require "sinatra"
require "uri"

require "code"
require "code/config"

module Code
  module API
    class Director < Sinatra::Application
      ACLS = {
        "25:25:85:78:31:f7:6e:46:04:9a:08:9b:8a:11:5c:a7" => ["code", "gentle-snow-22"]
      }

      DIRECTOR_API_URI            = URI.parse(Config.env("DIRECTOR_API_URL"))
      DIRECTOR_API_KEY            = DIRECTOR_API_URI.password
      DIRECTOR_API_URL            = "#{DIRECTOR_API_URI.scheme}://#{DIRECTOR_API_URI.host}:#{DIRECTOR_API_URI.port}"
      HEROKU_API_URL              = Config.env("HEROKU_API_URL", default: nil)
      REDIS_URL                   = Config.env("REDIS_URL")
      S3_URI                      = URI.parse(Config.env("S3_URL"))
      ENV["S3_ACCESS_KEY_ID"]     = S3_URI.user
      ENV["S3_SECRET_ACCESS_KEY"] = S3_URI.password   
      S3_BUCKET                   = "s3://#{S3_URI.host}"
      SESSION_KEY_SALT            = Config.env("SESSION_KEY_SALT")
      SESSION_TIMEOUT             = Config.env("SESSION_TIMEOUT", default: 30)

      helpers do
        def authorized_fingerprint?
          @auth ||= Rack::Auth::Basic::Request.new(request.env)
          return false unless @auth.provided? && @auth.basic? && @auth.credentials
          return false unless @auth.credentials[1] == DIRECTOR_API_KEY

          @fingerprint = CGI::unescape(@auth.credentials[0])
          !!ACLS[@fingerprint]
        end

        def authorized_key?
          @auth ||= Rack::Auth::Basic::Request.new(request.env)
          @auth.provided? && @auth.basic? && @auth.credentials && @auth.credentials[1] == DIRECTOR_API_KEY
        end

        def hash(key)
          OpenSSL::PKCS5::pbkdf2_hmac_sha1(key, SESSION_KEY_SALT, 1000, 24).unpack("H*")[0]
        end

        def heroku
          $heroku ||= Heroku::API.new(:api_key => URI.parse(HEROKU_API_URL).password)
        end

        def protected!
          unless authorized_key?
            response["WWW-Authenticate"] = %(Basic realm="Restricted Area")
            halt 401, "Not authorized\n"
          end

          @app_name = params[:app_name]
          @type     = params["type"]
          @sid      = hash("#{@app_name}_#{@type}")
          @key      = "session.#{@sid}"

          halt 404, "Not found\n" unless @app_name =~ /^[a-z][a-z0-9-]+$/
        end

        def redis
          $redis ||= Redis.new(:url => REDIS_URL)
        end

        def session
          halt 404, "Not found\n" unless redis.exists(@key)

          route = redis.hgetall @key
          redis.expire @key, SESSION_TIMEOUT

          if @type == "ssh"
            return <<-EOF.unindent
              HostName="#{route["hostname"]}"
              Port="#{route["port"]}"
              ##
              #{route["ssh_key"]}
              ##
              [#{route["hostname"]}]:#{route["port"]} ssh-rsa AAAAB3NzaC1yc2EAAAABIwAAAGEArzJx8OYOnJmzf4tfBEvLi8DVPrJ3/c9k2I/Az64fxjHf9imyRJbixtQhlH9lfNjUIx+4LmrJH5QNRsFporcHDKOTwTTYLh5KmRpslkYHRivcJSkbh/C+BR3utDS555mV
            EOF
          else
            return JSON.dump(route)
          end

        end

        def verify_session!(sid)
          @sid        = sid
          @key        = "session.#{@sid}"
          @reply_key  = "#{@key}.reply"

          halt 404, "Not found\n" unless redis.exists(@key)
        end
      end

      get "/ssh-access" do
        unless authorized_fingerprint?
          response["WWW-Authenticate"] = %(Basic realm="Restricted Area")
          halt 401, "Not authorized\n"
        end
      end

      get "/compiler/:app_name" do
        protected!
        session
      end

      post "/compiler/:app_name" do
        protected!

        if !redis.exists(@key)
          redis.hset    @key, "key", @key
          redis.expire  @key, SESSION_TIMEOUT

          env = {
            "BUILD_CALLBACK_URL"  => "",
            "CALLBACK_URL"        => "#{DIRECTOR_API_URL}/session/#{@sid}",
          }

          uuid = SecureRandom.uuid
          ENV["S3_URL"] = "#{S3_BUCKET}/slugs/#{uuid}.tgz"
          env.merge!({
            "SLUG_URL"     => "#{S3_BUCKET.gsub(/^s3/, "https")}.s3.amazonaws.com/slugs/#{uuid}.tgz",
            "SLUG_PUT_URL" => IO.popen(["bin/s3", "put", "--ttl=3600"]).read.strip
          })

          ENV["S3_URL"] = "#{S3_BUCKET}/caches/#{@app_name}.tgz"
          env.merge!({
            "CACHE_GET_URL" => IO.popen(["bin/s3", "get"]).read.strip,
            "CACHE_PUT_URL" => IO.popen(["bin/s3", "put", "--ttl=3600"]).read.strip,
          })

          ENV["S3_URL"] = "#{S3_BUCKET}/repos/#{@app_name}.bundle"
          env.merge!({
            "REPO_GET_URL" => IO.popen(["bin/s3", "get"]).read.strip,
            "REPO_PUT_URL" => IO.popen(["bin/s3", "put", "--ttl=3600"]).read.strip,
          })

          if @type == "ssh"
            ssh_key     = OpenSSL::PKey::RSA.new 2048
            data        = [ssh_key.to_blob].pack("m0")
            env.merge!({"SSH_PUB_KEY" => "#{ssh_key.ssh_type} #{data}"})
          end

          if HEROKU_API_URL
            heroku.post_ps("code-compiler", "#{@type}_compiler", :ps_env => env) # TODO: config var for app name
          else
            env.merge!({
              "ANVIL_DIR"   => File.expand_path(File.join(__FILE__, "..", "..", "..", "..", "vendor/anvil")),
              "PATH"        => ENV["PATH"],
              "PORT"        => (6000 + rand(100)).to_s,
              "VIRTUAL_ENV" => ENV["VIRTUAL_ENV"]
            })
            cmd = "bin/#{@type}-compiler"
            pid = Process.spawn(env, cmd, unsetenv_others: true)
          end

          # wait for compiler session callback
          k, v = redis.brpop "#{@key}.reply", SESSION_TIMEOUT
          halt 503, "No compiler available\n" if !v

          redis.hmset @key, "ssh_key", ssh_key if @type == "ssh"
        end

        session
      end

      put "/session/:sid" do
        verify_session!(params["sid"])

        redis.hmset   @key, "hostname", params["hostname"], "port", params["port"], "username", params["username"], "password", params["password"]
        redis.expire  @key, SESSION_TIMEOUT
        redis.rpush   @reply_key, "ok"
        redis.expire  @reply_key, SESSION_TIMEOUT

        "ok"
      end

      head "/session/:sid" do
        verify_session!(params["sid"])
        "ok"
      end

      delete "/session/:sid" do
        verify_session!(params["sid"])

        redis.del @key, @reply_key

        "ok"
      end
    end
  end
end