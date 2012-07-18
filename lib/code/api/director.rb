require "json"
require "openssl"
require "sinatra"
require "uri"

require "code/api/helpers"
require "code/config"

module Code
  module API
    class Director < Sinatra::Application
      DIRECTOR_API_URI        = URI.parse(Config.env("DIRECTOR_API_URL"))
      DIRECTOR_API_KEY        = DIRECTOR_API_URI.password; DIRECTOR_API_URI.password = nil
      DIRECTOR_API_URL        = DIRECTOR_API_URI.to_s
      REDIS_URL               = Config.env("REDIS_URL")
      S3_BUCKET               = Config.env("S3_BUCKET")
      SESSION_KEY_SALT        = Config.env("SESSION_KEY_SALT")
      SESSION_TIMEOUT         = Config.env("SESSION_TIMEOUT", default: 30)

      helpers Code::API::Helpers

      helpers do
        def authorized?
          @auth ||= Rack::Auth::Basic::Request.new(request.env)
          @auth.provided? && @auth.basic? && @auth.credentials && @auth.credentials[1] == DIRECTOR_API_KEY
        end

        def hash(key)
          OpenSSL::PKCS5::pbkdf2_hmac_sha1(key, SESSION_KEY_SALT, 1000, 24).unpack("H*")[0]
        end

        def protected!(app_name)
          unless authorized?
            response["WWW-Authenticate"] = %(Basic realm="Restricted Area")
            halt 401, "Not authorized\n"
          end

          halt 404, "Not found\n" unless app_name =~ /^[a-z][a-z0-9-]+$/

          @app_name = params[:app_name]
          @sid      = hash(@app_name)
          @key      = "session.#{@sid}"
        end

        def auth_session!(sid)
          @sid        = sid
          @key        = "session.#{@sid}"
          @reply_key  = "#{@key}.reply"

          halt 404, "Not found\n" unless redis.exists(@key)
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

        if redis.exists(@key)
          redis.expire @key, SESSION_TIMEOUT
          return JSON.dump(redis.hgetall @key)
        end

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

        cmd = "bin/ssh-compiler"
        cmd = "bin/http-compiler" if params["type"] == "http"
        pid = Process.spawn(env, cmd, unsetenv_others: true)

        return JSON.dump(redis.hgetall @key)
      end

      put "/session/:sid" do
        auth_session!(params["sid"])

        redis.hmset   @key, "hostname", params["hostname"], "port", params["port"], "username", params["username"], "password", params["password"]
        redis.expire  @key, SESSION_TIMEOUT
        redis.rpush   @reply_key, JSON.dump(redis.hgetall @key)
        redis.expire  @reply_key, SESSION_TIMEOUT

        "ok"
      end

      delete "/session/:sid" do
        auth_session!(params["sid"])

        redis.del @key, @reply_key

        "ok"
      end
    end
  end
end