require "cgi"
require "code"
require "sinatra"

module Code
  ACLS = {
    "25:25:85:78:31:f7:6e:46:04:9a:08:9b:8a:11:5c:a7" => ["code", "gentle-snow-22"]
  }
  COMPILER_API_KEY = env("COMPILER_API_KEY")

  module API
    class Compiler < Sinatra::Application

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

          # check that basic auth username is a valid [fingerprint, repository] pair
          @fingerprint = CGI::unescape(@auth.credentials[0])
          if acl = ACLS[@fingerprint]
            return acl.include?(params["repository"])
          end

          return false
        end
      end

      post "/:repository" do
        protected!
        "hello #{@fingerprint}, here is your #{params["repository"]}"
      end
    end
  end
end