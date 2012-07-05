require "cgi"
require "code"
require "json"
require "net/ssh"
require "redis"
require "securerandom"
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
        # authorize fingerprint and API key
        protected!
        "ok"
      end

      post "/:app_name" do
        protected!
        throw(:halt, [404, "Not found\n"]) unless params["app_name"] =~ /^[a-z][a-z0-9-]+$/
        throw(:halt, [404, "Not found\n"]) unless ACLS[@fingerprint].include?(params["app_name"])

        xid       = SecureRandom.hex(8)
        key       = "compiler.session.#{xid}"
        reply_key = "#{key}.reply"

        # generate a one-time-use SSH key pair
        ssh_key     = OpenSSL::PKey::RSA.new 2048
        data        = [ ssh_key.to_blob ].pack("m0")
        ssh_pub_key = "#{ssh_key.ssh_type} #{data}"

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
          "SSH_PUB_KEY"         => ssh_pub_key,
          "REPO_GET_URL"        => "",
          "REPO_PUT_URL"        => "",
        }

        # runtime environment
        env.merge!({
          "PATH"        => ENV["PATH"],
          "PORT"        => (6000 + rand(100)).to_s,
          "VIRTUAL_ENV" => ENV["VIRTUAL_ENV"]
        })
        
        pid = Process.spawn(env, "bin/ssh-compiler", unsetenv_others: true)

        # wait for compiler callback
        k, v = redis.brpop reply_key, COMPILER_REPLY_TIMEOUT
        if v
          data = JSON.parse(v)

          # send host, port and private key 
          # plain text format can be `csplit` into session config files
          return <<-EOF.unindent
            HostName="#{data["hostname"]}"
            Port="#{data["port"]}"
            #---
            #{ssh_key}
          EOF
        else
          status 503
          "No compiler available\n"
        end
      end

      put %r{/session/([0-9a-f]{16})$} do |xid|
        key       = "compiler.session.#{xid}"
        reply_key = "#{key}.reply"

        throw(:halt, [404, "Not found\n"]) unless redis.exists(key)

        data = params.select { |k, v| ["hostname", "port"].include?(k) }
        redis.rpush   reply_key, JSON.dump(data)
        redis.expire  reply_key, COMPILER_REPLY_TIMEOUT
      end

      post "/session/record" do
        protected!

        key = "compiler.records"
        data = {
          app_name: params["app_name"],
          log:      params["log"][:tempfile].read
        }
        redis.rpush key, data
        "ok"
      end
    end
  end
end