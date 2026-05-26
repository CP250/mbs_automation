/*
 * Daily Auto-Open — built from src/ with esbuild. Do not edit main.js by hand.
 * Rebuild with: npm install && npm run build
 */
"use strict";
var __defProp = Object.defineProperty;
var __getOwnPropDesc = Object.getOwnPropertyDescriptor;
var __getOwnPropNames = Object.getOwnPropertyNames;
var __hasOwnProp = Object.prototype.hasOwnProperty;
var __export = (target, all) => {
  for (var name in all)
    __defProp(target, name, { get: all[name], enumerable: true });
};
var __copyProps = (to, from, except, desc) => {
  if (from && typeof from === "object" || typeof from === "function") {
    for (let key of __getOwnPropNames(from))
      if (!__hasOwnProp.call(to, key) && key !== except)
        __defProp(to, key, { get: () => from[key], enumerable: !(desc = __getOwnPropDesc(from, key)) || desc.enumerable });
  }
  return to;
};
var __toCommonJS = (mod) => __copyProps(__defProp({}, "__esModule", { value: true }), mod);

// src/main.ts
var main_exports = {};
__export(main_exports, {
  default: () => DailyAutoOpenPlugin
});
module.exports = __toCommonJS(main_exports);
var import_obsidian = require("obsidian");
var DEFAULT_SETTINGS = {
  openOnStartup: true,
  pinTabs: true,
  rotateStale: true,
  startupDelayMs: 1200,
  notes: [
    { name: "health", folder: "daily_notes/health/daily", filename: "daily_note_health_{{date}}", dateFormat: "YYYY-MM-DD" },
    { name: "tasks", folder: "daily_notes/tasks", filename: "tasks_{{date}}", dateFormat: "YYYY-MM-DD" }
  ]
};
function escapeRe(s) {
  return s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}
function dateTokenRe(fmt) {
  return escapeRe(fmt).replace(/YYYY/g, "\\d{4}").replace(/MM/g, "\\d{2}").replace(/DD/g, "\\d{2}");
}
function formatToday(fmt) {
  const d = /* @__PURE__ */ new Date();
  const yyyy = String(d.getFullYear());
  const mm = String(d.getMonth() + 1).padStart(2, "0");
  const dd = String(d.getDate()).padStart(2, "0");
  return fmt.replace(/YYYY/g, yyyy).replace(/MM/g, mm).replace(/DD/g, dd);
}
var DailyAutoOpenPlugin = class extends import_obsidian.Plugin {
  async onload() {
    await this.loadSettings();
    this.addSettingTab(new DAOSettingTab(this.app, this));
    this.addCommand({
      id: "open-todays-dailies",
      name: "Open today's daily notes",
      callback: () => this.openDailies()
    });
    this.app.workspace.onLayoutReady(() => {
      if (!this.settings.openOnStartup)
        return;
      window.setTimeout(() => this.openDailies(), Math.max(0, this.settings.startupDelayMs));
    });
    this.registerEvent(
      this.app.vault.on("create", (file) => {
        if (!(file instanceof import_obsidian.TFile))
          return;
        if (!this.settings.openOnStartup)
          return;
        const todayPaths = new Set(this.settings.notes.map((s) => this.todayPath(s)));
        if (todayPaths.has(file.path)) {
          window.setTimeout(() => this.openDailies(), 250);
        }
      })
    );
  }
  todayPath(spec) {
    const stamp = formatToday(spec.dateFormat || "YYYY-MM-DD");
    const fname = spec.filename.replace(/\{\{date\}\}/g, stamp);
    return (0, import_obsidian.normalizePath)(`${spec.folder}/${fname}.md`);
  }
  // Regex matching this spec's notes for ANY date (used to find stale tabs).
  specPathRe(spec) {
    const folder = spec.folder.replace(/^\/+|\/+$/g, "");
    const parts = spec.filename.split("{{date}}").map(escapeRe);
    const fnameRe = parts.join(dateTokenRe(spec.dateFormat || "YYYY-MM-DD"));
    return new RegExp("^" + escapeRe(folder) + "/" + fnameRe + "\\.md$");
  }
  // File path of a leaf — read from view STATE so it works even for deferred
  // (lazy, not-yet-loaded) restored tabs, where leaf.view.file is undefined.
  leafPath(leaf) {
    var _a;
    const st = leaf.getViewState();
    const sf = st && st.state ? st.state.file : void 0;
    if (typeof sf === "string" && sf)
      return sf;
    const vf = (_a = leaf.view) == null ? void 0 : _a.file;
    return vf == null ? void 0 : vf.path;
  }
  async openDailies() {
    var _a;
    const specs = this.settings.notes;
    const todayByPath = /* @__PURE__ */ new Map();
    specs.forEach((s) => todayByPath.set(this.todayPath(s), s));
    const regexes = specs.map((s) => this.specPathRe(s));
    const byPath = /* @__PURE__ */ new Map();
    this.app.workspace.iterateAllLeaves((leaf) => {
      const p = this.leafPath(leaf);
      if (!p)
        return;
      const arr = byPath.get(p) || [];
      arr.push(leaf);
      byPath.set(p, arr);
    });
    if (this.settings.rotateStale) {
      for (const [p, leaves] of byPath) {
        if (todayByPath.has(p))
          continue;
        if (regexes.some((r) => r.test(p)))
          leaves.forEach((l) => l.detach());
      }
    }
    let missing = 0;
    for (const path of todayByPath.keys()) {
      const existing = byPath.get(path) || [];
      let keep = existing[0] || null;
      existing.slice(1).forEach((l) => l.detach());
      if (!keep) {
        const af = this.app.vault.getAbstractFileByPath(path);
        if (!(af instanceof import_obsidian.TFile)) {
          missing++;
          continue;
        }
        keep = this.app.workspace.getLeaf("tab");
        await keep.openFile(af, { active: false });
      }
      if (this.settings.pinTabs && keep) {
        (_a = keep.setPinned) == null ? void 0 : _a.call(keep, true);
      }
    }
    if (missing > 0) {
      new import_obsidian.Notice(`Daily Auto-Open: ${missing} of today's notes not found yet \u2014 they'll open once created.`);
    }
  }
  async loadSettings() {
    this.settings = Object.assign({}, DEFAULT_SETTINGS, await this.loadData());
  }
  async saveSettings() {
    await this.saveData(this.settings);
  }
};
var DAOSettingTab = class extends import_obsidian.PluginSettingTab {
  constructor(app, plugin) {
    super(app, plugin);
    this.plugin = plugin;
  }
  display() {
    const { containerEl } = this;
    containerEl.empty();
    containerEl.createEl("h2", { text: "Daily Auto-Open" });
    new import_obsidian.Setting(containerEl).setName("Open on startup").setDesc("Open today's daily notes automatically when Obsidian launches.").addToggle(
      (t) => t.setValue(this.plugin.settings.openOnStartup).onChange(async (v) => {
        this.plugin.settings.openOnStartup = v;
        await this.plugin.saveSettings();
      })
    );
    new import_obsidian.Setting(containerEl).setName("Pin as tabs").setDesc("Keep the opened notes pinned so they persist as tabs (desktop) / stay open (mobile).").addToggle(
      (t) => t.setValue(this.plugin.settings.pinTabs).onChange(async (v) => {
        this.plugin.settings.pinTabs = v;
        await this.plugin.saveSettings();
      })
    );
    new import_obsidian.Setting(containerEl).setName("Rotate stale tabs").setDesc("On open, close previous days' daily-note tabs so only today's stay open.").addToggle(
      (t) => t.setValue(this.plugin.settings.rotateStale).onChange(async (v) => {
        this.plugin.settings.rotateStale = v;
        await this.plugin.saveSettings();
      })
    );
    new import_obsidian.Setting(containerEl).setName("Startup delay (ms)").setDesc("Wait this long after launch before opening, so the Journals plugin can create today's notes first.").addText(
      (t) => t.setValue(String(this.plugin.settings.startupDelayMs)).onChange(async (v) => {
        const n = parseInt(v, 10);
        this.plugin.settings.startupDelayMs = isNaN(n) ? 1200 : n;
        await this.plugin.saveSettings();
      })
    );
    containerEl.createEl("h3", { text: "Notes opened each day" });
    containerEl.createEl("p", {
      text: "Each note: folder + filename (use {{date}}) + date format. Defaults match your Journals health + tasks notes.",
      cls: "setting-item-description"
    });
    this.plugin.settings.notes.forEach((spec, i) => {
      const s = new import_obsidian.Setting(containerEl).setName(spec.name || `note ${i + 1}`);
      s.addText(
        (t) => t.setPlaceholder("folder").setValue(spec.folder).onChange(async (v) => {
          spec.folder = v.trim();
          await this.plugin.saveSettings();
        })
      );
      s.addText(
        (t) => t.setPlaceholder("filename_{{date}}").setValue(spec.filename).onChange(async (v) => {
          spec.filename = v.trim();
          await this.plugin.saveSettings();
        })
      );
    });
  }
};
