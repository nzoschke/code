require "cgi"
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

      DIRECTOR_API_URI        = URI.parse(Config.env("DIRECTOR_API_URL"))
      DIRECTOR_API_KEY        = DIRECTOR_API_URI.password
      DIRECTOR_API_URL        = "#{DIRECTOR_API_URI.scheme}://#{DIRECTOR_API_URI.host}:#{DIRECTOR_API_URI.port}"
      REDIS_URL               = Config.env("REDIS_URL")
      S3_BUCKET               = Config.env("S3_BUCKET")
      SESSION_KEY_SALT        = Config.env("SESSION_KEY_SALT")
      SESSION_TIMEOUT         = Config.env("SESSION_TIMEOUT", default: 30)

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

        def protected!(app_name)
          unless authorized_key?
            response["WWW-Authenticate"] = %(Basic realm="Restricted Area")
            halt 401, "Not authorized\n"
          end

          halt 404, "Not found\n" unless app_name =~ /^[a-z][a-z0-9-]+$/

          @app_name = params[:app_name]
          @sid      = hash(@app_name)
          @key      = "session.#{@sid}"
        end

        def redis
          @redis ||= Redis.new(:url => REDIS_URL)
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
        protected!(params["app_name"])

        if redis.exists(@key)
          redis.expire @key, SESSION_TIMEOUT
          return JSON.dump(redis.hgetall @key)
        end

        halt 404, "Not found\n"
      end

      post "/compiler/:app_name" do
        protected!(params["app_name"])

        if !redis.exists(@key)
          redis.hset    @key, "key", @key
          redis.expire  @key, SESSION_TIMEOUT

          env = {
            "BUILD_CALLBACK_URL"  => "",
            "BUILD_PUT_URL"       => "",
            "CALLBACK_URL"        => "#{DIRECTOR_API_URL}/session/#{@sid}",
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

          # TODO: replace with `heroku run` call for secure LXC container
          # local runtime environment
          env.merge!({
            "PATH"        => ENV["PATH"],
            "PORT"        => (6000 + rand(100)).to_s,
            "VIRTUAL_ENV" => ENV["VIRTUAL_ENV"]
          })

          cmd = "bin/http-compiler"
          if params["type"] == "ssh"
            cmd = "bin/ssh-compiler"

            ssh_key     = OpenSSL::PKey::RSA.new 2048
            data        = [ssh_key.to_blob].pack("m0")
            env.merge!({"SSH_PUB_KEY" => "#{ssh_key.ssh_type} #{data}"})
          end

          pid = Process.spawn(env, cmd, unsetenv_others: true)

          # wait for compiler session callback
          k, v = redis.brpop "#{@key}.reply", SESSION_TIMEOUT
          halt 503, "No compiler available\n" if !v

          redis.hmset @key, "ssh_key", ssh_key if params["type"] == "ssh"
        end

        route = redis.hgetall @key

        if params["type"] == "ssh"
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