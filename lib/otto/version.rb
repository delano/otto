#

class Otto
  # Otto::VERSION
  #
  module VERSION
    def self.to_s
      load_config
      version = self.version
      [version[:MAJOR], version[:MINOR], version[:PATCH]].join('.')
    end

    def self.inspect
      to_s
    end

    def self.load_config
      require 'yaml'
      self.version ||= YAML.load_file(File.join(LIB_HOME, '..', 'VERSION.yml'))
    end
  end
end
