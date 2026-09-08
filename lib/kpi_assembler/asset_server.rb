# frozen_string_literal: true

module KPIAssembler
  # Serves the workspace's static UI files as a plain Rack endpoint.
  #
  # These files carry no tenant data, so they do not need the host application's
  # controller stack — and routing them through it is actively harmful: Rails
  # raises InvalidCrossOriginRequest (422) for a `.js` response rendered inside
  # the forgery-protection chain, which breaks the <script> tag on the page.
  class AssetServer
    ROOT = ::File.expand_path("../../public", __dir__)

    CONTENT_TYPES = {
      "app.css" => "text/css",
      "app.js" => "text/javascript",
      "kpi-assembler.js" => "text/javascript"
    }.freeze

    def call(env)
      name = env["PATH_INFO"].to_s.delete_prefix("/")
      content_type = CONTENT_TYPES[name]
      return not_found unless content_type

      body = ::File.binread(::File.join(ROOT, name))
      [
        200,
        {
          "content-type" => "#{content_type}; charset=utf-8",
          "content-length" => body.bytesize.to_s,
          "cache-control" => "public, max-age=300"
        },
        [body]
      ]
    end

    private

    def not_found
      [404, { "content-type" => "text/plain", "content-length" => "9" }, ["Not found"]]
    end
  end
end
