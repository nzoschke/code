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

        uuid      = "%08x" % rand(2**64) # fast per-request unique id
        key       = "compiler.session.#{uuid}"
        reply_key = "#{key}.reply"

        redis.set     key, request.ip
        redis.expire  key, COMPILER_REPLY_TIMEOUT

        Process.fork do
          sleep 1
          `curl -s -X PUT http://localhost:5000/compiler/session/#{uuid} -d "hostname=localhost"`
        end

        k, v = redis.brpop reply_key, COMPILER_REPLY_TIMEOUT
        if v
          data = JSON.parse(v)
          "hello #{@fingerprint}, here is your #{params["repository"]}: #{data}\n"
        else
          status 503
          "No compiler available\n"
        end
      end

      put "/session/:uuid" do
        key       = "compiler.session.#{params["uuid"]}"
        reply_key = "#{key}.reply"

        throw(:halt, [404, "Not found\n"]) unless redis.exists(key)

        data = params.select { |k, v| ["hostname", "port", "public_key"].include?(k) }
        redis.rpush   reply_key, JSON.dump(data)
        redis.expire  reply_key, COMPILER_REPLY_TIMEOUT
      end
    end
  end
end