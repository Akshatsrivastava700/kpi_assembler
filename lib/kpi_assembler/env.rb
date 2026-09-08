# frozen_string_literal: true

module KPIAssembler
  # Loads KEY=VALUE pairs from a .env file without overriding values already
  # present in the process environment.
  module Env
    module_function

    def load!(path)
      return unless path && File.file?(path)

      File.foreach(path) do |line|
        line = line.strip
        next if line.empty? || line.start_with?("#")

        key, value = line.split("=", 2)
        next if key.nil? || value.nil?

        key = key.strip
        next if key.empty? || ENV.key?(key)

        ENV[key] = unquote(value.strip)
      end
    end

    def load_defaults!
      load!(File.expand_path("../../.env", __dir__))
      load!(File.expand_path(".env"))
    end

    def unquote(value)
      if (value.start_with?('"') && value.end_with?('"')) ||
         (value.start_with?("'") && value.end_with?("'"))
        value[1..-2]
      else
        value
      end
    end
  end
end
