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

// src/rotation.ts
function stalePathsToDetach(openPaths, specs, todayExists) {
  const todayPaths = new Set(specs.map((s) => s.todayPath));
  const out = [];
  for (const p of openPaths) {
    if (todayPaths.has(p))
      continue;
    const owner = specs.find((s) => s.pathRe.test(p));
    if (!owner)
      continue;
    if (todayExists.has(owner.todayPath))
      out.push(p);
  }
  return out;
}

// src/main.ts
var DEFAULT_SETTINGS = {
  openOnStartup: true,
  pinTabs: true,
  rotateStale: true,
  startupDelayMs: 1200,
  notes: [
    { name: "health", folder: "daily_notes/health/daily", filename: "daily_note_health_{{date}}", dateFormat: "YYYY-MM-DD" },
    { name: "tasks", folder: "daily_notes/tasks", filename: "tasks_{{date}}", dateFormat: "YYYY-MM-DD" }
  ],
  preferredParentIds: {},
  preferredPositions: {}
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
  // v0.1.5: resolve a directional position ('leftmost' | 'rightmost') to the id
  // of the tabs container at that edge of the main root split, at runtime. This
  // survives workspace rebuilds because we walk the live layout instead of
  // remembering a UUID. If the edge child is itself a split (nested layout), we
  // descend along the same edge until we hit a tabs container.
  edgeTabsId(position) {
    const root = this.app.workspace.rootSplit;
    if (!root || !Array.isArray(root.children) || root.children.length === 0)
      return void 0;
    const pickEdge = (arr) => position === "leftmost" ? arr[0] : arr[arr.length - 1];
    let node = pickEdge(root.children);
    for (let depth = 0; depth < 16; depth++) {
      if (!node)
        return void 0;
      const n = node;
      if (n.type === "tabs")
        return n.id;
      if (!Array.isArray(n.children) || n.children.length === 0)
        return n.id;
      if (n.type === "split") {
        node = pickEdge(n.children);
        continue;
      }
      node = pickEdge(n.children);
    }
    return void 0;
  }
  // v0.1.5: find any leaf whose parent matches the given tabs container id.
  // Used to setActiveLeaf so getLeaf('tab') opens in the same parent.
  findLeafByParentId(parentId) {
    let found;
    this.app.workspace.iterateAllLeaves((leaf) => {
      var _a;
      if (found)
        return;
      const pid = (_a = leaf.parent) == null ? void 0 : _a.id;
      if (pid === parentId)
        found = leaf;
    });
    return found;
  }
  async openDailies() {
    var _a, _b, _c, _d;
    const specs = this.settings.notes;
    const todayByPath = /* @__PURE__ */ new Map();
    specs.forEach((s) => todayByPath.set(this.todayPath(s), s));
    const byPath = /* @__PURE__ */ new Map();
    this.app.workspace.iterateAllLeaves((leaf) => {
      const p = this.leafPath(leaf);
      if (!p)
        return;
      const arr = byPath.get(p) || [];
      arr.push(leaf);
      byPath.set(p, arr);
    });
    const staleBySpec = /* @__PURE__ */ new Map();
    for (const [p, leaves] of byPath) {
      if (todayByPath.has(p))
        continue;
      for (const spec of specs) {
        if (this.specPathRe(spec).test(p)) {
          const tp = this.todayPath(spec);
          const arr = staleBySpec.get(tp) || [];
          arr.push(...leaves);
          staleBySpec.set(tp, arr);
        }
      }
    }
    let missing = 0;
    let settingsDirty = false;
    const todayExists = /* @__PURE__ */ new Set();
    for (const [path, spec] of todayByPath.entries()) {
      const existing = byPath.get(path) || [];
      let keep = existing[0] || null;
      existing.slice(1).forEach((l) => l.detach());
      const position = (_a = this.settings.preferredPositions) == null ? void 0 : _a[spec.name];
      if (!keep) {
        const af = this.app.vault.getAbstractFileByPath(path);
        if (!(af instanceof import_obsidian.TFile)) {
          missing++;
          continue;
        }
        let placed = false;
        if (position) {
          const edgeId = this.edgeTabsId(position);
          if (edgeId) {
            const target = this.findLeafByParentId(edgeId);
            if (target) {
              this.app.workspace.setActiveLeaf(target, { focus: false });
              placed = true;
            }
          }
        }
        if (!placed) {
          const staleLeaves = staleBySpec.get(path) || [];
          if (staleLeaves.length > 0) {
            this.app.workspace.setActiveLeaf(staleLeaves[0], { focus: false });
            placed = true;
          }
        }
        if (!placed) {
          const savedId = (_b = this.settings.preferredParentIds) == null ? void 0 : _b[spec.name];
          if (savedId) {
            const target = this.findLeafByParentId(savedId);
            if (target) {
              this.app.workspace.setActiveLeaf(target, { focus: false });
              placed = true;
            }
          }
        }
        keep = this.app.workspace.getLeaf("tab");
        await keep.openFile(af, { active: false });
        if (!position) {
          const newParentId = (_c = keep.parent) == null ? void 0 : _c.id;
          if (newParentId) {
            if (!this.settings.preferredParentIds)
              this.settings.preferredParentIds = {};
            if (this.settings.preferredParentIds[spec.name] !== newParentId) {
              this.settings.preferredParentIds[spec.name] = newParentId;
              settingsDirty = true;
            }
          }
        }
      }
      if (keep)
        todayExists.add(path);
      if (this.settings.pinTabs && keep) {
        (_d = keep.setPinned) == null ? void 0 : _d.call(keep, true);
      }
    }
    if (settingsDirty)
      await this.saveSettings();
    if (this.settings.rotateStale) {
      const rotationSpecs = specs.map((s) => ({ todayPath: this.todayPath(s), pathRe: this.specPathRe(s) }));
      for (const p of stalePathsToDetach(byPath.keys(), rotationSpecs, todayExists)) {
        (byPath.get(p) || []).forEach((l) => l.detach());
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
      s.addDropdown((d) => {
        var _a, _b;
        d.addOption("", "auto (drag-to-learn)");
        d.addOption("leftmost", "leftmost pane");
        d.addOption("rightmost", "rightmost pane");
        const current = (_b = (_a = this.plugin.settings.preferredPositions) == null ? void 0 : _a[spec.name]) != null ? _b : "";
        d.setValue(current);
        d.onChange(async (v) => {
          if (!this.plugin.settings.preferredPositions)
            this.plugin.settings.preferredPositions = {};
          if (v === "") {
            delete this.plugin.settings.preferredPositions[spec.name];
          } else {
            this.plugin.settings.preferredPositions[spec.name] = v;
          }
          await this.plugin.saveSettings();
        });
      });
    });
    containerEl.createEl("p", {
      text: 'Position picker (v0.1.5): "auto" preserves prior behavior (auto-learns from drags via UUID). "leftmost"/"rightmost" resolve to the actual edge pane of the main split at runtime \u2014 survives workspace rebuilds and saved-workspace loads.',
      cls: "setting-item-description"
    });
  }
};
