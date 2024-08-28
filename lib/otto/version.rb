#

class Otto
  # Otto::VERSION
  #
  module VERSION
    def self.to_a
      load_config
      [@version[:MAJOR], @version[:MINOR], @version[:PATCH]]
    end

    def self.to_s
      version = to_a.join('.')
      "#{version}-#{@version[:PRE]}" if @version[:PRE]
    end

    def self.inspect
      to_s
    end

    def self.load_config
      return if @version
      require 'yaml'
      @version = YAML.load_file(File.join(__dir__, '..', '..', 'VERSION.yml'))
    end
  end
end
