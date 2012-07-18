require "code/config"
require "redis"

module Code
  module API
    module Helpers
      REDIS_URL = Config.env("REDIS_URL")

      def redis
        @redis ||= Redis.new(:url => REDIS_URL)
      end
    end
  end
end