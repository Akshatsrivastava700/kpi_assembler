# frozen_string_literal: true

require "json"
require "cgi"

module KPIAssembler
  class HtmlReport
    def initialize(pack, locations: [])
      @pack = pack
      @locations = locations
    end

    def render
      <<~HTML
        <!DOCTYPE html>
        <html lang="en">
        <head>
          <meta charset="utf-8">
          <title>#{h(@pack[:pack_name])}</title>
          <style>
            :root { --bg:#0f1419; --card:#1a2332; --muted:#8b9bb4; --ok:#3dd68c; --draft:#f5c542; --bad:#ff6b6b; --line:#2a3548; --text:#e8eef7; }
            * { box-sizing: border-box; }
            body { margin:0; font-family: ui-sans-serif, system-ui, sans-serif; background:var(--bg); color:var(--text); }
            header { padding:28px 32px 12px; border-bottom:1px solid var(--line); }
            header p { color:var(--muted); max-width:720px; }
            main { padding:24px 32px 64px; }
            h1 { margin:0 0 8px; font-size:28px; }
            h2 { margin:28px 0 12px; font-size:18px; letter-spacing:.02em; }
            .badge { display:inline-block; padding:2px 8px; border-radius:999px; font-size:12px; font-weight:600; }
            .ok { background:#143d2c; color:var(--ok); }
            .draft { background:#3d3414; color:var(--draft); }
            .grid { display:grid; grid-template-columns:repeat(auto-fill,minmax(220px,1fr)); gap:12px; }
            .card { background:var(--card); border:1px solid var(--line); border-radius:12px; padding:16px; }
            .card.dim { opacity:.55; }
            .value { font-size:28px; font-weight:700; margin:8px 0 0; }
            .muted { color:var(--muted); font-size:13px; }
            table { width:100%; border-collapse:collapse; background:var(--card); border-radius:12px; overflow:hidden; }
            th, td { text-align:left; padding:10px 12px; border-bottom:1px solid var(--line); font-size:14px; vertical-align:top; }
            th { color:var(--muted); font-weight:600; }
            pre { white-space:pre-wrap; font-size:12px; color:#c5d4ea; margin:0; }
            .tabs { display:flex; gap:8px; flex-wrap:wrap; margin:8px 0 16px; }
            .tabs button { background:#243044; color:var(--text); border:1px solid var(--line); border-radius:8px; padding:8px 12px; cursor:pointer; }
            .tabs button.active { background:#2f6fed; border-color:#2f6fed; }
            .panel { display:none; }
            .panel.active { display:block; }
            .brief { font-size:16px; line-height:1.5; }
          </style>
        </head>
        <body>
          <header>
            <h1>#{h(@pack[:pack_name])}</h1>
            <p>#{h(@pack[:principle])} Draft metrics never reach the board or the briefing.</p>
            <p class="muted">Generated #{h(@pack[:generated_at])} · #{h(@pack[:certified_by])}</p>
          </header>
          <main>
            <h2>Weekly briefing</h2>
            <div class="card brief">#{h(briefing_headline)}</div>
            #{drill_html}

            <h2>Role views</h2>
            <div class="tabs">
              <button class="active" data-panel="exec">Exec (all sites)</button>
              #{location_tab_buttons}
            </div>
            <div id="exec" class="panel active">#{kpi_grid(evaluations_for(nil))}</div>
            #{location_panels}

            <h2>Metric catalog</h2>
            <table>
              <thead>
                <tr><th>Status</th><th>Name</th><th>Definition</th><th>Grain</th><th>Owner</th><th>Why draft?</th></tr>
              </thead>
              <tbody>#{catalog_rows}</tbody>
            </table>
          </main>
          <script>
            document.querySelectorAll('.tabs button').forEach(function(btn) {
              btn.addEventListener('click', function() {
                document.querySelectorAll('.tabs button').forEach(function(b) { b.classList.remove('active'); });
                document.querySelectorAll('.panel').forEach(function(p) { p.classList.remove('active'); });
                btn.classList.add('active');
                document.getElementById(btn.dataset.panel).classList.add('active');
              });
            });
          </script>
        </body>
        </html>
      HTML
    end

    private

    def briefing_headline
      @pack.dig(:briefing, :headline) || "No briefing."
    end

    def drill_html
      drill = @pack.dig(:briefing, :drill_dimension) || {}
      site = drill[:explaining_site]
      return "" unless site

      rows = Array(drill[:locations]).map { |l| "#{h(l[:name])}: #{h(l[:value])}" }.join(" · ")
      %(<p class="muted">Drill on location — weakest site for #{h(drill[:kpi_id])}: <strong>#{h(site[:name])}</strong> (#{h(site[:value])}). #{rows}</p>)
    end

    def evaluations_for(location_id)
      key = location_id.nil? ? "all" : location_id.to_s
      (@pack[:evaluations] || {}).fetch(key, {})
    end

    def kpi_grid(values)
      certified = Array(@pack[:kpis]).map do |kpi|
        val = values[kpi[:id]]
        <<~CARD
          <div class="card">
            <span class="badge ok">certified</span>
            <div class="muted">#{h(kpi[:name])}</div>
            <div class="value">#{h(format_value(val))}</div>
          </div>
        CARD
      end
      drafts = Array(@pack[:drafts]).map do |kpi|
        <<~CARD
          <div class="card dim">
            <span class="badge draft">draft</span>
            <div class="muted">#{h(kpi[:name])}</div>
            <div class="value">—</div>
            <div class="muted">Failed certification; excluded from the board.</div>
          </div>
        CARD
      end
      %(<div class="grid">#{certified.join}#{drafts.join}</div>)
    end

    def location_tab_buttons
      @locations.map do |loc|
        %(<button data-panel="loc-#{loc[:id]}">Site manager · #{h(loc[:name])}</button>)
      end.join
    end

    def location_panels
      @locations.map do |loc|
        %(<div id="loc-#{loc[:id]}" class="panel">#{kpi_grid(evaluations_for(loc[:id]))}</div>)
      end.join
    end

    def catalog_rows
      Array(@pack[:catalog]).map do |entry|
        badge = entry[:status] == "certified" ? %(<span class="badge ok">certified</span>) : %(<span class="badge draft">draft</span>)
        reasons = Array(entry[:reasons]).map { |r| h(r) }.join("<br>")
        <<~TR
          <tr>
            <td>#{badge}</td>
            <td>#{h(entry[:name])}<div class="muted"><code>#{h(entry[:id])}</code></div></td>
            <td>#{h(entry[:english])}<pre>#{h(entry[:sql])}</pre></td>
            <td>#{h(entry[:grain])}</td>
            <td>#{h(entry[:owner])}</td>
            <td>#{reasons.empty? ? "—" : reasons}</td>
          </tr>
        TR
      end.join
    end

    def format_value(val)
      return "n/a" if val.nil?

      n = Float(val)
      n.abs >= 100 ? format("%.0f", n) : format("%.1f", n)
    rescue ArgumentError, TypeError
      val.to_s
    end

    def h(value)
      CGI.escapeHTML(value.to_s)
    end
  end
end
