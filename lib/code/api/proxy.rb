require "sinatra"

module Code
  module API
    class Proxy < Sinatra::Application
      get "/" do
        "hello proxy"
      end
    end
  end
end