#

class Otto
  # Otto::VERSION
  #
  module VERSION
    def self.to_a
      load_config
      version = [@version[:MAJOR], @version[:MINOR], @version[:PATCH]]
      version << @version[:PRE] unless @version.fetch(:PRE, nil).to_s.empty?
      version
    end

    def self.to_s
      to_a.join('.')
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
