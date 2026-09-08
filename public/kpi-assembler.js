(function () {
  "use strict";

  class KPIAssemblerElement extends HTMLElement {
    static get observedAttributes() {
      return ["service-url", "height"];
    }

    constructor() {
      super();
      this.attachShadow({ mode: "open" });
    }

    connectedCallback() {
      this.render();
    }

    attributeChangedCallback() {
      if (this.isConnected) this.render();
    }

    render() {
      const source = (this.getAttribute("service-url") || window.location.origin).replace(/\/$/, "");
      const height = this.getAttribute("height") || "760px";

      this.shadowRoot.innerHTML = `
        <style>
          :host { display: block; width: 100%; }
          .frame {
            position: relative;
            width: 100%;
            height: ${this.safeCssSize(height)};
            min-height: 560px;
            border: 1px solid #e4e5ec;
            border-radius: 14px;
            background: #fafafd;
            box-shadow: 0 14px 40px rgba(34, 31, 76, .08);
            overflow: hidden;
          }
          iframe { width: 100%; height: 100%; border: 0; background: #fafafd; }
        </style>
        <div class="frame">
          <iframe
            src="${this.escapeAttribute(source)}/?embed=1"
            title="KPIAssembler metric certification"
            loading="lazy"
            allow="clipboard-write"
          ></iframe>
        </div>`;

      this.shadowRoot.querySelector("iframe").addEventListener("load", () => {
        this.dispatchEvent(new CustomEvent("kpi-assembler-ready", {
          bubbles: true,
          detail: { serviceUrl: source }
        }));
      });
    }

    safeCssSize(value) {
      return /^(\d+(\.\d+)?)(px|rem|em|vh|%)$/.test(value) ? value : "760px";
    }

    escapeAttribute(value) {
      return String(value)
        .replaceAll("&", "&amp;")
        .replaceAll('"', "&quot;")
        .replaceAll("<", "&lt;")
        .replaceAll(">", "&gt;");
    }
  }

  if (!customElements.get("kpi-assembler")) {
    customElements.define("kpi-assembler", KPIAssemblerElement);
  }
}());
