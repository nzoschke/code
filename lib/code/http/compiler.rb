require "code/config"
require "excon"
require "git_http"

module Code
  module HTTP
    class Compiler
      CALLBACK_URL  = Config.env("CALLBACK_URL")
      PORT          = Config.env("PORT")

      def initialize
        session_dir = IO.popen([
          "./bin/template", "etc/compiler-session",
          "CACHE_GET_URL", "CACHE_PUT_URL", "CALLBACK_URL", "REPO_GET_URL", "REPO_PUT_URL"
        ]) { |io| io.read }.strip

        pid = Process.spawn("./init.sh", chdir: session_dir, unsetenv_others: true)
        Process.wait(pid)

        @app = GitHttp::App.new({
          :project_root => session_dir,
          :upload_pack  => true,
          :receive_pack => true,
        })
      end

      def call(env)
        r = @app.call(env)
        Compiler.put_server_info
        r
      end

      def self.put_server_info
        @ip ||= UDPSocket.open { |s| s.connect("64.233.187.99", 1); s.addr.last }
        begin
          Excon.new(CALLBACK_URL).put(:query => {:hostname => @ip, :port => PORT})
        rescue Excon::Errors::SocketError => e
          puts e.inspect
        end
      end
    end
  end
end