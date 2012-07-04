require "cgi"
require "code"
require "json"
require "redis"
require "sinatra"

module Code
  module API
    class Compiler < Sinatra::Application
      ACLS = {
        "25:25:85:78:31:f7:6e:46:04:9a:08:9b:8a:11:5c:a7" => ["code", "gentle-snow-22"]
      }
      COMPILER_API_KEY        = Config.env("COMPILER_API_KEY")
      COMPILER_REPLY_TIMEOUT  = Config.env("COMPILER_REPLY_TIMEOUT", default: 30)
      REDIS_URL               = Config.env("REDIS_URL")

      helpers do
        def protected!
          unless authorized?
            response["WWW-Authenticate"] = %(Basic realm="Restricted Area")
            throw(:halt, [401, "Not authorized\n"])
          end
        end

        def authorized?
          # check that basic auth password is a valid API key
          @auth ||=  Rack::Auth::Basic::Request.new(request.env)
          return false unless @auth.provided? && @auth.basic? && @auth.credentials
          return false unless @auth.credentials[1] == COMPILER_API_KEY

          # check that basic auth username is a valid fingerprint
          @fingerprint = CGI::unescape(@auth.credentials[0])
          !!ACLS[@fingerprint]
        end

        def redis
          @redis ||= Redis.new(:url => REDIS_URL)
        end
      end

      get "/" do
        protected!
        "ok"
      end

      post "/:repository" do
        protected!
        throw(:halt, [404, "Not found\n"]) unless ACLS[@fingerprint].include?(params["repository"])

        xid       = "%08x" % rand(2**64) # fast per-request unique id
        key       = "compiler.session.#{xid}"
        reply_key = "#{key}.reply"

        redis.set     key, request.ip
        redis.expire  key, COMPILER_REPLY_TIMEOUT

        # fork ssh-compiler process
        # can be securely implemented via a `heroku run` API call
        env = {
          "BUILD_CALLBACK_URL"  => "",
          "BUILD_PUT_URL"       => "",
          "CACHE_GET_URL"       => "",
          "CACHE_PUT_URL"       => "",
          "CALLBACK_URL"        => "http://localhost:5000/compiler/session/#{xid}",
          "PORT"                => "6022",
          "SSH_PUB_KEY"         => params["ssh_pub_key"][:tempfile].read,
          "REPO_GET_URL"        => "",
          "REPO_PUT_URL"        => "",
        }

        env.merge!({
          "PATH"        => ENV["PATH"],
          "VIRTUAL_ENV" => ENV["VIRTUAL_ENV"]
        })
        
        pid = Process.spawn(env, "bin/ssh-compiler", unsetenv_others: true)

        # wait for compiler callback
        k, v = redis.brpop reply_key, COMPILER_REPLY_TIMEOUT
        if v
          data = JSON.parse(v)
          "hello #{@fingerprint}, here is your #{params["repository"]}: #{data}\n"
        else
          status 503
          "No compiler available\n"
        end
      end

      put "/session/:xid" do
        key       = "compiler.session.#{params["xid"]}"
        reply_key = "#{key}.reply"

        throw(:halt, [404, "Not found\n"]) unless redis.exists(key)

        data = params.select { |k, v| ["hostname", "port"].include?(k) }
        redis.rpush   reply_key, JSON.dump(data)
        redis.expire  reply_key, COMPILER_REPLY_TIMEOUT
      end
    end
  end
end