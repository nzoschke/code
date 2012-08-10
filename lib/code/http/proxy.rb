require "code/config"
require "excon"
require "json"
require "rack/streaming_proxy"
require "sinatra"

module Code
  module HTTP
    class Proxy < Sinatra::Application
      DIRECTOR_API_URL        = Config.env("DIRECTOR_API_URL")
      SESSION_TIMEOUT         = Config.env("SESSION_TIMEOUT", default: 30)

      helpers do
        def api
          @api ||= Excon.new(DIRECTOR_API_URL)
        end

        def protected!
          @app_name = params[:app_name]
          halt 404, "Not found\n" unless @app_name =~ /^[a-z][a-z0-9-]+$/

          # TODO: auth against core
        end

        def proxy(hostname, port=80, username=nil, password=nil)
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

        def proxy_session(opts={method: :get})
          protected!

          # create (:post) or use existing (:get) compiler session
          opts.merge!({
            path: "/compiler/#{@app_name}",
            query: {type: "http"}
          })
          response = api.request(opts)
          halt 502, "Error\n" unless response.status == 200

          route = JSON.parse(response.body)
          return proxy(route["hostname"], route["port"], route["username"], route["password"]) if route["hostname"]

          halt 503, "No compiler available\n"
        end
      end

      get "/:app_name.git/info/refs" do
        proxy_session(method: :post)
      end

      post "/:app_name.git/git-receive-pack" do
        proxy_session
      end

      post "/:app_name.git/git-upload-pack" do
        proxy_session
      end
    end
  end
end