# frozen_string_literal: true

module KPIAssembler
  class WorkspaceController < ApplicationController
    def show
      base = request.script_name.to_s.sub(%r{/\z}, "")
      html = File.read(KPIAssembler::Engine.root.join("public/index.html"))
      html.sub!('<meta name="kpi-api-base" content="/api/v1">', %(<meta name="kpi-api-base" content="#{base}/api/v1">))
      html.sub!('href="/app.css"', %(href="#{base}/assets/app.css"))
      html.sub!('src="/app.js"', %(src="#{base}/assets/app.js"))
      html.gsub!("http://localhost:9292/kpi-assembler.js", "#{request.base_url}#{base}/assets/kpi-assembler.js")
      html.gsub!('service-url="http://localhost:9292"', %(service-url="#{request.base_url}#{base}"))

      render html: html.html_safe, layout: false
    end
  end
end
