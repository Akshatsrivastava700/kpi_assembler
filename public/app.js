(function () {
  "use strict";

  const state = {
    candidates: [],
    selected: new Set(),
    rankedTables: new Set(),
    activeLocation: "all"
  };

  const $ = (selector) => document.querySelector(selector);
  const $$ = (selector) => Array.from(document.querySelectorAll(selector));
  const apiBase = document.querySelector('meta[name="kpi-api-base"]')?.content.replace(/\/$/, "") || "/api/v1";

  if (new URLSearchParams(window.location.search).get("embed") === "1") {
    document.body.classList.add("embed");
  }

  function escapeHtml(value) {
    return String(value == null ? "" : value)
      .replaceAll("&", "&amp;")
      .replaceAll("<", "&lt;")
      .replaceAll(">", "&gt;")
      .replaceAll('"', "&quot;")
      .replaceAll("'", "&#039;");
  }

  async function api(path, options) {
    const response = await fetch(path, {
      credentials: "same-origin",
      headers: {
        "Content-Type": "application/json",
        Accept: "application/json",
        // Host apps commonly redirect non-XHR requests to a login page.
        "X-Requested-With": "XMLHttpRequest"
      },
      ...options
    });
    let payload;
    try {
      payload = await response.json();
    } catch (_error) {
      throw new Error(
        "The service returned " + response.status + " " + response.statusText +
          " instead of JSON (" + path + ")."
      );
    }
    if (!response.ok) throw new Error(payload.error || "Request failed with " + response.status + ".");
    return payload;
  }

  function setLoading(button, loading) {
    button.disabled = loading;
    button.classList.toggle("loading", loading);
  }

  let toastTimer;
  function toast(message, type) {
    const node = $("#toast");
    node.textContent = message;
    node.className = "toast show" + (type === "error" ? " error" : "");
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => { node.className = "toast"; }, 3200);
  }

  function showView(name) {
    $$(".view").forEach((view) => view.classList.remove("active"));
    $("#" + name + "-view").classList.add("active");
    $$(".nav-item").forEach((item) => {
      item.classList.toggle("active", item.dataset.view === name);
    });

    const titles = {
      workspace: "Metric discovery",
      dashboard: "Trusted analytics",
      integration: "Integration"
    };
    $("#page-title").textContent = titles[name];
    window.scrollTo({ top: 0, behavior: "smooth" });
  }

  async function checkHealth() {
    const status = $("#api-status");
    try {
      await api(apiBase + "/health");
      status.className = "api-status online";
      status.innerHTML = "<i></i> Service connected";
    } catch (_error) {
      status.className = "api-status error";
      status.innerHTML = "<i></i> Service unavailable";
    }
  }

  async function discover() {
    const buttons = [$("#discover-button"), $("#rediscover-button")];
    buttons.forEach((button) => setLoading(button, true));
    try {
      const result = await api(apiBase + "/discover", { method: "POST", body: "{}" });
      const tables = result.tables || [];
      state.candidates = result.candidates || [];
      state.rankedTables = new Set(result.ranked_tables || []);
      state.selected = new Set(state.candidates.map((candidate) => String(candidate.id)));
      renderSchema(tables);
      renderCandidates();
      renderDiscoveryNotice(result);
      $("#source-label").textContent = sourceLabel(result, tables);
      $("#proposal-subtitle").textContent = proposalSubtitle(result);
      $("#discovery-results").classList.remove("hidden");
      $("#discovery-results").scrollIntoView({ behavior: "smooth", block: "start" });
      toast(
        tables.length === 0
          ? "Discovery found no tables. Check the configured table names."
          : proposalToast(result),
        tables.length === 0 || result.proposer_fallback ? "error" : undefined
      );
    } catch (error) {
      toast(error.message, "error");
    } finally {
      buttons.forEach((button) => setLoading(button, false));
    }
  }

  function renderDiscoveryNotice(result) {
    const notice = $("#discovery-notice");
    const missing = result.missing_tables || [];
    const messages = [];

    if (missing.length) {
      messages.push(
        "Configured but not found in the database: <strong>" +
          missing.map(escapeHtml).join(", ") +
          "</strong>. Check spelling" +
          (result.schema_name ? ", or whether they live outside schema \"" + escapeHtml(result.schema_name) + '"' : "") +
          "."
      );
    }
    const omitted = result.omitted_tables || [];
    if (omitted.length) {
      messages.push(
        "Dropped by the <code>max_tables</code> limit of " + escapeHtml(result.max_tables) +
          ": <strong>" + omitted.map(escapeHtml).join(", ") + "</strong>. Raise the limit to include them."
      );
    }
    if (!(result.tables || []).length) {
      messages.push("No tables were read, so there is nothing to propose. Update <code>config.include_tables</code> and restart the application.");
    }
    if (result.proposer_fallback) {
      messages.push(
        "LLM proposal was not used (" + escapeHtml(result.proposer_fallback) +
          "). Showing schema-driven heuristics instead."
      );
    } else if (result.proposer === "llm") {
      const ranked = result.ranked_tables || [];
      messages.push(
        "LLM ranked " + ranked.length + " table" + (ranked.length === 1 ? "" : "s") +
          (ranked.length ? " (<strong>" + ranked.map(escapeHtml).join(", ") + "</strong>)" : "") +
          " and proposed KPIs. Heuristics filled any gaps. SQL is still untrusted until certification."
      );
    }

    notice.innerHTML = messages.join("<br>");
    notice.classList.toggle("hidden", messages.length === 0);
  }

  function sourceLabel(result, tables) {
    const bits = [result.source, tables.length + " tables"];
    if (result.schema_name) bits.push("schema " + result.schema_name);
    if (result.proposer === "llm") {
      bits.push("proposer " + (result.proposer_model || "llm"));
    } else {
      bits.push("proposer heuristics");
    }
    return bits.join(" · ");
  }

  function proposalSubtitle(result) {
    if (result.proposer === "llm") {
      return "The model ranked discovered tables and wrote recipes. They are not trusted until certification.";
    }
    if (result.proposer_fallback) {
      return "Heuristics proposed these metrics because the LLM was unavailable.";
    }
    return "Schema heuristics proposed these metrics. Configure Gemini or Ollama to let the model rank tables.";
  }

  function proposalToast(result) {
    if (result.proposer === "llm") return "LLM proposed metrics from the discovered schema.";
    if (result.proposer_fallback) return "LLM unavailable — showing heuristic KPIs.";
    return "Discovery complete. Review the proposed definitions.";
  }

  function renderSchema(tables) {
    $("#schema-summary").innerHTML = tables.map((table) => {
      const columns = (table.columns || []).slice(0, 4).map((column) => escapeHtml(column.name)).join(" · ");
      const more = (table.columns || []).length > 4 ? " +" + ((table.columns || []).length - 4) : "";
      const ranked = state.rankedTables.has(table.name);
      return `
        <article class="schema-card${ranked ? " ranked" : ""}">
          <span class="schema-icon">▤</span>
          <strong>${escapeHtml(table.name)}</strong>
          <small>${ranked ? "LLM-ranked · " : ""}${escapeHtml(table.row_count)} rows · ${(table.foreign_keys || []).length} relations</small>
          <div class="column-list">${columns}${more}</div>
        </article>`;
    }).join("");
  }

  function renderCandidates() {
    $("#candidate-list").innerHTML = state.candidates.map((candidate) => {
      const id = String(candidate.id);
      const selected = state.selected.has(id);
      return `
        <article class="candidate ${selected ? "selected" : ""}" data-id="${escapeHtml(id)}">
          <input type="checkbox" aria-label="Select ${escapeHtml(candidate.name)}" ${selected ? "checked" : ""}>
          <div class="candidate-name">
            <strong>${escapeHtml(candidate.name)}</strong>
            <small>${escapeHtml(candidate.category)} · owner: ${escapeHtml(candidate.owner || "unassigned")} · ${escapeHtml(candidate.source || "heuristics")}</small>
          </div>
          <div class="candidate-definition">${escapeHtml(candidate.formula_description)}</div>
          <span class="grain">${escapeHtml(candidate.grain)}</span>
          <button class="sql-toggle" type="button" aria-label="View SQL">&lt;/&gt;</button>
          <pre class="candidate-sql">${escapeHtml(candidate.sql)}</pre>
        </article>`;
    }).join("");
    updateSelectedCount();

    $$(".candidate").forEach((card) => {
      card.addEventListener("click", (event) => {
        if (event.target.closest(".sql-toggle")) {
          event.preventDefault();
          event.stopPropagation();
          card.classList.toggle("open");
          return;
        }
        const checkbox = card.querySelector("input");
        if (event.target !== checkbox) checkbox.checked = !checkbox.checked;
        setSelected(card.dataset.id, checkbox.checked, card);
      });
    });
  }

  function setSelected(id, selected, card) {
    if (selected) state.selected.add(id);
    else state.selected.delete(id);
    card.classList.toggle("selected", selected);
    updateSelectedCount();
  }

  function updateSelectedCount() {
    $("#selected-count").textContent = state.selected.size;
    $("#certify-button").disabled = state.selected.size === 0;
  }

  async function certify() {
    const button = $("#certify-button");
    setLoading(button, true);
    try {
      state.pack = await api(apiBase + "/certify", {
        method: "POST",
        body: JSON.stringify({ accepted_ids: Array.from(state.selected) })
      });
      state.activeLocation = "all";
      renderPack();
      showView("dashboard");
      toast(
        state.pack.kpis.length + " certified · " + state.pack.drafts.length + " held as draft"
      );
    } catch (error) {
      toast(error.message, "error");
    } finally {
      setLoading(button, false);
    }
  }

  function renderPack() {
    const pack = state.pack;
    if (!pack) return;

    $("#empty-dashboard").classList.add("hidden");
    $("#pack-content").classList.remove("hidden");
    $("#briefing-headline").textContent = pack.briefing.headline;
    const drill = pack.briefing.drill_dimension || {};
    $("#briefing-drill").textContent = drill.explaining_site
      ? "Location drill: " + drill.explaining_site.name + " is the lowest site for " + drill.kpi_id + "."
      : "No location-level exception was detected.";

    renderRoleTabs();
    renderMetricGrid();
    $("#certification-report").innerHTML = (pack.catalog || []).map((entry) => {
      const passed = entry.status === "certified";
      const explanation = passed
        ? "Passed schema, join safety, division safety, grain, query-plan, and sample replay checks."
        : (entry.reasons || []).join(" · ");
      return `
        <article class="report-row">
          <span class="report-status ${passed ? "" : "draft"}">${escapeHtml(entry.status)}</span>
          <strong>${escapeHtml(entry.name)}</strong>
          <p>${escapeHtml(explanation)}</p>
        </article>`;
    }).join("");
  }

  function renderRoleTabs() {
    const tabs = [{ id: "all", name: "Executive · All sites" }].concat(
      (state.pack.locations || []).map((location) => ({
        id: String(location.id),
        name: "Site manager · " + location.name
      }))
    );
    $("#role-tabs").innerHTML = tabs.map((tab) => `
      <button class="role-tab ${state.activeLocation === tab.id ? "active" : ""}" data-location="${escapeHtml(tab.id)}">
        ${escapeHtml(tab.name)}
      </button>`).join("");
    $$(".role-tab").forEach((tab) => {
      tab.addEventListener("click", () => {
        state.activeLocation = tab.dataset.location;
        renderRoleTabs();
        renderMetricGrid();
      });
    });
  }

  function renderMetricGrid() {
    const values = (state.pack.evaluations || {})[state.activeLocation] || {};
    $("#metric-grid").innerHTML = (state.pack.kpis || []).map((kpi) => `
      <article class="metric-card">
        <div class="metric-label"><span>${escapeHtml(kpi.name)}</span><i class="status-dot"></i></div>
        <div class="metric-value">${escapeHtml(formatMetric(values[kpi.id], kpi))}</div>
        <small>Certified · ${escapeHtml(kpi.grain)} grain · ${escapeHtml(kpi.owner)}</small>
      </article>`).join("");
  }

  function formatMetric(value, kpi) {
    if (value == null) return "No data";
    const number = Number(value);
    const name = String(kpi.name).toLowerCase();
    if (name.includes("rate") || name.includes("conversion")) return number.toFixed(1) + "%";
    if (name.includes("revenue") || name.includes("mrr")) {
      return new Intl.NumberFormat("en-US", { style: "currency", currency: "USD", maximumFractionDigits: 0 }).format(number);
    }
    return new Intl.NumberFormat("en-US", { maximumFractionDigits: 1 }).format(number);
  }

  function downloadPack() {
    if (!state.pack) return;
    const blob = new Blob([JSON.stringify(state.pack, null, 2)], { type: "application/json" });
    const link = document.createElement("a");
    link.href = URL.createObjectURL(blob);
    link.download = "kpi-pack.json";
    link.click();
    URL.revokeObjectURL(link.href);
  }

  $$(".nav-item").forEach((item) => item.addEventListener("click", () => showView(item.dataset.view)));
  $("#integration-shortcut").addEventListener("click", () => showView("integration"));
  $("#discover-button").addEventListener("click", discover);
  $("#rediscover-button").addEventListener("click", discover);
  $("#certify-button").addEventListener("click", certify);
  $("#back-to-catalog").addEventListener("click", () => showView("workspace"));
  $("#empty-discover").addEventListener("click", () => { showView("workspace"); discover(); });
  $("#download-pack").addEventListener("click", downloadPack);

  $$(".copy-button").forEach((button) => {
    button.addEventListener("click", async () => {
      const target = $("#" + button.dataset.copy);
      await navigator.clipboard.writeText(target.textContent);
      button.textContent = "Copied";
      setTimeout(() => { button.textContent = "Copy"; }, 1400);
    });
  });

  checkHealth();
}());
