# frozen_string_literal: true

module BOMEngine
  module Branding
    EXTENSION_NAME = 'Sibambo BOMC Engine'
    EXTENSION_VERSION = '1.2.0'
    BOMC_FORMAT_VERSION = '1.2'
    DESCRIPTION = 'Compiled BOMC 1.2 exporter for SketchUp with Exact, Research, and Visual profiles.'

    module_function

    def build_sha
      path = File.join(__dir__, 'BUILD_SHA.txt')
      return 'development' unless File.file?(path)

      value = File.read(path, encoding: 'UTF-8').strip
      value.empty? ? 'development' : value
    end

    def short_build_sha(value = self.build_sha)
      value == 'development' ? value : value[0, 12]
    end

    def about_text(build_sha: self.build_sha)
      short_build = short_build_sha(build_sha)
      <<~TEXT.strip
        #{EXTENSION_NAME}
        Extension version: #{EXTENSION_VERSION}
        BOMC format: #{BOMC_FORMAT_VERSION}
        Build: #{short_build}
        Build SHA: #{build_sha}

        Compiled building export for web-first Sibambo workflows.
        Profiles: Exact, Research, Visual.
      TEXT
    end
  end
end
