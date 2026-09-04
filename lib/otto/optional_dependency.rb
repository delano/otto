# frozen_string_literal: true

require 'rubygems'

class Otto
  # Raised when an explicitly enabled feature cannot load its optional gem.
  class OptionalDependencyError < ArgumentError; end

  # Loads optional gems against the compatibility ranges Otto supports.
  module OptionalDependency
    module_function

    def require!(gem_name, requirement, require_path:, feature:, alternative: nil)
      version_requirement = Gem::Requirement.new(requirement)
      guidance = "Add `gem '#{gem_name}', '#{requirement}'` to your Gemfile."
      guidance = "#{guidance} #{alternative}" if alternative
      installed_specs = Gem::Specification.find_all_by_name(gem_name)
      active_spec = Gem.loaded_specs[gem_name]
      compatible_spec = if active_spec && version_requirement.satisfied_by?(active_spec.version)
                          active_spec
                        else
                          installed_specs
                            .select { |spec| version_requirement.satisfied_by?(spec.version) }
                            .max_by(&:version)
                        end

      unless compatible_spec
        installed = installed_specs.map(&:version).sort.join(', ')
        reason = installed.empty? ? 'it is not installed' : "installed version(s) #{installed} are incompatible"
        raise OptionalDependencyError,
              "#{feature} requires optional dependency '#{gem_name}' (#{version_requirement}), but #{reason}. #{guidance}"
      end

      load_error = begin
        compatible_spec.activate
        require require_path
        nil
      # Convert loader failures into a feature-specific configuration error.
      # rubocop:disable-next Lint/ShadowedException
      rescue Gem::LoadError, LoadError => e
        e
      end

      raise_load_error!(feature, gem_name, version_requirement, guidance, load_error) if load_error

      compatible_spec
    end

    def raise_load_error!(feature, gem_name, requirement, guidance, error)
      raise OptionalDependencyError,
            "#{feature} requires optional dependency '#{gem_name}' (#{requirement}), but it could not be " \
            "loaded: #{error.message}. #{guidance}",
            cause: error
    end
  end
end
