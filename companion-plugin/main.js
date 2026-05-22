/*
 * MBS Companion — built from src/ with esbuild. Do not edit main.js directly.
 * See RELEASING.md / README.md for the build steps (npm install && npm run build).
 */
var __create = Object.create;
var __defProp = Object.defineProperty;
var __getOwnPropDesc = Object.getOwnPropertyDescriptor;
var __getOwnPropNames = Object.getOwnPropertyNames;
var __getProtoOf = Object.getPrototypeOf;
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
var __toESM = (mod, isNodeMode, target) => (target = mod != null ? __create(__getProtoOf(mod)) : {}, __copyProps(
  // If the importer is in node compatibility mode or this is not an ESM
  // file that has been converted to a CommonJS file using a Babel-
  // compatible transform (i.e. "__esModule" has not been set), then set
  // "default" to the CommonJS "module.exports" for node compatibility.
  isNodeMode || !mod || !mod.__esModule ? __defProp(target, "default", { value: mod, enumerable: true }) : target,
  mod
));
var __toCommonJS = (mod) => __copyProps(__defProp({}, "__esModule", { value: true }), mod);

// src/main.ts
var main_exports = {};
__export(main_exports, {
  default: () => MbsCompanionPlugin
});
module.exports = __toCommonJS(main_exports);
var import_obsidian = require("obsidian");
var fs = __toESM(require("fs"));
var os = __toESM(require("os"));
var path = __toESM(require("path"));
var import_child_process = require("child_process");
var DEFAULT_SETTINGS = {
  vaultPath: "/Users/cpreston/Vaults/storage_mbs",
  commandsDir: path.join(os.homedir(), ".claude", "commands"),
  claudeBin: "/opt/homebrew/bin/claude",
  stateDir: path.join(os.homedir(), ".mbs_automation"),
  reviewsDir: "admin/reviews",
  sessionReportDir: "admin/obsidian_optimize/session_awareness"
};
var STATUS_VALUES = ["done", "skip", "defer"];
function todayStr() {
  const d = /* @__PURE__ */ new Date();
  const m = String(d.getMonth() + 1).padStart(2, "0");
  const day = String(d.getDate()).padStart(2, "0");
  return `${d.getFullYear()}-${m}-${day}`;
}
function isoWeekStr() {
  const now = /* @__PURE__ */ new Date();
  const d = new Date(Date.UTC(now.getFullYear(), now.getMonth(), now.getDate()));
  const dayNum = (d.getUTCDay() + 6) % 7;
  d.setUTCDate(d.getUTCDate() - dayNum + 3);
  const firstThursday = new Date(Date.UTC(d.getUTCFullYear(), 0, 4));
  const week = 1 + Math.round((d.getTime() - firstThursday.getTime()) / (7 * 864e5));
  return `${d.getUTCFullYear()}-W${String(week).padStart(2, "0")}`;
}
function readStamp(file) {
  try {
    return fs.readFileSync(file, "utf8").trim();
  } catch (e) {
    return null;
  }
}
function readLogTail(file, n) {
  try {
    const stat = fs.statSync(file);
    const text = fs.readFileSync(file, "utf8");
    const lines = text.split("\n").filter((l) => l.trim().length > 0);
    return { mtime: stat.mtimeMs, lines: lines.slice(-n) };
  } catch (e) {
    return null;
  }
}
var MbsCompanionPlugin = class extends import_obsidian.Plugin {
  constructor() {
    super(...arguments);
    this.statusEl = null;
  }
  async onload() {
    await this.loadSettings();
    this.statusEl = this.addStatusBarItem();
    this.statusEl.addClass("mbs-status");
    this.registerDomEvent(this.statusEl, "click", () => this.openDailyNote());
    this.addCommand({
      id: "open-daily",
      name: "Open today's daily note",
      callback: () => this.openDailyNote()
    });
    this.addCommand({
      id: "open-weekly-review",
      name: "Open latest weekly review",
      callback: () => this.openNewestIn(this.settings.reviewsDir)
    });
    this.addCommand({
      id: "open-session-report",
      name: "Open latest session-awareness report",
      callback: () => this.openNewestIn(this.settings.sessionReportDir)
    });
    this.addCommand({
      id: "run-daily",
      name: "Run daily report now",
      callback: () => this.runDaily()
    });
    this.addCommand({
      id: "run-health",
      name: "Run health audit now",
      callback: () => this.runHealth()
    });
    this.addCommand({
      id: "refresh-status",
      name: "Refresh agent status",
      callback: () => this.refreshStatus()
    });
    this.addCommand({
      id: "cycle-vault-agent-status",
      name: "Cycle Vault Agent item status (done | skip | defer)",
      editorCallback: (editor, view) => this.cycleVaultAgentStatus(editor)
    });
    this.addCommand({
      id: "open-status-panel",
      name: "Open status panel",
      callback: () => new MbsStatusModal(this.app, this).open()
    });
    this.addSettingTab(new MbsSettingTab(this.app, this));
    this.refreshStatus();
    this.registerInterval(window.setInterval(() => this.refreshStatus(), 5 * 60 * 1e3));
  }
  async loadSettings() {
    this.settings = Object.assign({}, DEFAULT_SETTINGS, await this.loadData());
  }
  async saveSettings() {
    await this.saveData(this.settings);
  }
  refreshStatus() {
    if (!this.statusEl)
      return;
    const daily = readStamp(path.join(this.settings.stateDir, "last_daily_run"));
    const weekly = readStamp(path.join(this.settings.stateDir, "last_weekly_run"));
    const dOk = daily === todayStr();
    const wOk = weekly === isoWeekStr();
    this.statusEl.setText(`\u{1F9E0} daily ${dOk ? "\u2713" : "\u2013"} \xB7 wk ${wOk ? "\u2713" : "\u2013"}`);
    this.statusEl.toggleClass("mbs-pending", !dOk);
    this.statusEl.setAttribute(
      "aria-label",
      `mbs-daily last run: ${daily || "never"} (today is ${todayStr()})
mbs-weekly last run: ${weekly || "never"} (this week is ${isoWeekStr()})
Click to open today's note`
    );
  }
  async openDailyNote() {
    await this.openByPath(`daily_notes/tasks/tasks_${todayStr()}.md`);
  }
  async openByPath(rel) {
    const f = this.app.vault.getAbstractFileByPath(rel);
    if (f instanceof import_obsidian.TFile) {
      await this.app.workspace.getLeaf(false).openFile(f);
    } else {
      new import_obsidian.Notice(`MBS: not there yet \u2014 ${rel}`);
    }
  }
  async openNewestIn(relDir) {
    const f = this.newestFileIn(relDir);
    if (!f) {
      new import_obsidian.Notice(`MBS: no usable note in ${relDir}`);
      return;
    }
    await this.app.workspace.getLeaf(false).openFile(f);
  }
  // Newest .md TFile in a vault-relative folder, or null (no notice — callers decide).
  newestFileIn(relDir) {
    const folder = this.app.vault.getAbstractFileByPath(relDir);
    if (!(folder instanceof import_obsidian.TFolder))
      return null;
    const mds = folder.children.filter(
      (c) => c instanceof import_obsidian.TFile && c.extension === "md"
    );
    if (!mds.length)
      return null;
    mds.sort((a, b) => (b.stat.mtime || 0) - (a.stat.mtime || 0));
    return mds[0];
  }
  // --- Vault Agent inline reply (v0.2.0) -----------------------------------
  // For the list item under the cursor, set/cycle its `status:` field through
  // done -> skip -> defer -> done. Only operates on lines inside a `## Vault
  // Agent` block; never touches P's own sections.
  cycleVaultAgentStatus(editor) {
    const cursor = editor.getCursor();
    const lineCount = editor.lineCount();
    if (!this.isInsideVaultAgent(editor, cursor.line)) {
      new import_obsidian.Notice("MBS: cursor is not inside a ## Vault Agent section");
      return;
    }
    let statusLine = -1;
    for (let i = cursor.line; i < lineCount; i++) {
      const text = editor.getLine(i);
      if (i > cursor.line && /^\s*- /.test(text))
        break;
      if (/^#{1,6}\s/.test(text))
        break;
      if (/^\s*status:/.test(text)) {
        statusLine = i;
        break;
      }
    }
    if (statusLine === -1) {
      for (let i = cursor.line; i >= 0; i--) {
        const text = editor.getLine(i);
        if (/^#{1,6}\s/.test(text))
          break;
        if (i < cursor.line && /^\s*- /.test(text))
          break;
        if (/^\s*status:/.test(text)) {
          statusLine = i;
          break;
        }
      }
    }
    if (statusLine === -1) {
      new import_obsidian.Notice("MBS: no `status:` line found for this item");
      return;
    }
    const original = editor.getLine(statusLine);
    const indentMatch = original.match(/^(\s*)status:/);
    const indent = indentMatch ? indentMatch[1] : "    ";
    const current = this.parseStatus(original);
    const next = this.nextStatus(current);
    const updated = `${indent}status: ${next}`;
    editor.setLine(statusLine, updated);
    new import_obsidian.Notice(`MBS: status -> ${next}`);
  }
  parseStatus(line) {
    const after = line.replace(/^\s*status:\s*/, "").trim();
    for (const v of STATUS_VALUES) {
      if (after === v)
        return v;
    }
    return null;
  }
  nextStatus(current) {
    if (current === null)
      return "done";
    const idx = STATUS_VALUES.indexOf(current);
    return STATUS_VALUES[(idx + 1) % STATUS_VALUES.length];
  }
  // True if `line` falls under a `## Vault Agent` heading and before the next
  // heading at the same (H2) or higher level.
  isInsideVaultAgent(editor, line) {
    let inside = false;
    for (let i = 0; i <= line; i++) {
      const text = editor.getLine(i);
      const h = text.match(/^(#{1,6})\s+(.*)$/);
      if (!h)
        continue;
      const level = h[1].length;
      const title = h[2].trim();
      if (level <= 2) {
        inside = level === 2 && /^vault agent\b/i.test(title);
      }
    }
    return inside;
  }
  // --- Headless runs -------------------------------------------------------
  runDaily() {
    const prompt = `Read ${this.settings.commandsDir}/obsidian-daily.md and carry out its instructions exactly, using the mbs_automation skill, against the vault at ${this.settings.vaultPath}. Append or refresh the bounded ## Vault Agent section in today's tasks note via the filesystem; do not touch P's own sections.`;
    this.runClaude(prompt, "daily report");
  }
  runHealth() {
    const prompt = `Read ${this.settings.commandsDir}/obsidian-health.md and carry out the health audit against the vault at ${this.settings.vaultPath}. Report only \u2014 do not apply any fixes.`;
    this.runClaude(prompt, "health audit");
  }
  runClaude(prompt, label) {
    new import_obsidian.Notice(`MBS: running ${label}\u2026 (this can take a few minutes)`);
    const env = Object.assign({}, process.env, {
      PATH: `/opt/homebrew/bin:/usr/local/bin:${path.join(os.homedir(), ".local/bin")}:${process.env.PATH || ""}`
    });
    const cmd = `"${this.settings.claudeBin}" -p ${JSON.stringify(prompt)} --dangerously-skip-permissions`;
    (0, import_child_process.exec)(cmd, { cwd: this.settings.vaultPath, env, maxBuffer: 32 * 1024 * 1024 }, (err) => {
      if (err) {
        new import_obsidian.Notice(`MBS: ${label} failed \u2014 ${err.message}`);
        return;
      }
      new import_obsidian.Notice(`MBS: ${label} done`);
      this.refreshStatus();
    });
  }
};
var MbsStatusModal = class extends import_obsidian.Modal {
  constructor(app, plugin) {
    super(app);
    this.plugin = plugin;
  }
  onOpen() {
    const { contentEl } = this;
    const s = this.plugin.settings;
    contentEl.empty();
    contentEl.addClass("mbs-status-panel");
    contentEl.createEl("h2", { text: "MBS Companion \u2014 status" });
    const daily = readStamp(path.join(s.stateDir, "last_daily_run"));
    const weekly = readStamp(path.join(s.stateDir, "last_weekly_run"));
    const dOk = daily === todayStr();
    const wOk = weekly === isoWeekStr();
    const runs = contentEl.createDiv({ cls: "mbs-section" });
    runs.createEl("h3", { text: "Scheduled agents" });
    const dailyLog = readLogTail(path.join(s.stateDir, "mbs_daily.log"), 1);
    const weeklyLog = readLogTail(path.join(s.stateDir, "mbs_weekly.log"), 1);
    this.row(runs, "mbs-daily", `${daily || "never"} ${dOk ? "\u2713" : "\u2013 (today is " + todayStr() + ")"}`);
    if (dailyLog) {
      this.subRow(runs, `log ${new Date(dailyLog.mtime).toLocaleString()}: ${dailyLog.lines[0] || ""}`);
    }
    this.row(runs, "mbs-weekly", `${weekly || "never"} ${wOk ? "\u2713" : "\u2013 (this week is " + isoWeekStr() + ")"}`);
    if (weeklyLog) {
      this.subRow(runs, `log ${new Date(weeklyLog.mtime).toLocaleString()}: ${weeklyLog.lines[0] || ""}`);
    }
    const sess = contentEl.createDiv({ cls: "mbs-section" });
    sess.createEl("h3", { text: "Session awareness" });
    const report = this.plugin.newestFileIn(s.sessionReportDir);
    if (report) {
      this.row(sess, "latest report", report.basename);
      this.app.vault.cachedRead(report).then((text) => {
        const leaks = this.parseLeakCount(text);
        this.row(sess, "leaks", leaks !== null ? String(leaks) : "not stated");
      });
    } else {
      this.row(sess, "latest report", "none yet");
    }
    const links = contentEl.createDiv({ cls: "mbs-section" });
    links.createEl("h3", { text: "Quick links" });
    this.link(links, "Today's daily note", () => {
      this.plugin.openDailyNote();
      this.close();
    });
    this.link(links, "Latest weekly review", () => {
      this.plugin.openNewestIn(s.reviewsDir);
      this.close();
    });
    this.link(links, "Latest session report", () => {
      this.plugin.openNewestIn(s.sessionReportDir);
      this.close();
    });
  }
  // Pull the leak count from a session-awareness report. Matches phrasings like
  // "Found **2 leaks**", "Found 1 leak", "**0 leaks**".
  parseLeakCount(text) {
    const m = text.match(/(\d+)\s*\*{0,2}\s*leaks?\b/i);
    return m ? parseInt(m[1], 10) : null;
  }
  row(parent, label, value) {
    const r = parent.createDiv({ cls: "mbs-row" });
    r.createSpan({ cls: "mbs-label", text: label });
    r.createSpan({ cls: "mbs-value", text: value });
  }
  subRow(parent, value) {
    parent.createDiv({ cls: "mbs-subrow", text: value });
  }
  link(parent, text, onClick) {
    const a = parent.createEl("a", { cls: "mbs-link", text, href: "#" });
    a.addEventListener("click", (e) => {
      e.preventDefault();
      onClick();
    });
  }
  onClose() {
    this.contentEl.empty();
  }
};
var MbsSettingTab = class extends import_obsidian.PluginSettingTab {
  constructor(app, plugin) {
    super(app, plugin);
    this.plugin = plugin;
  }
  display() {
    const { containerEl } = this;
    containerEl.empty();
    containerEl.createEl("h2", { text: "MBS Companion" });
    const add = (name, desc, key) => new import_obsidian.Setting(containerEl).setName(name).setDesc(desc).addText(
      (t) => t.setValue(this.plugin.settings[key]).onChange(async (v) => {
        this.plugin.settings[key] = v.trim();
        await this.plugin.saveSettings();
        this.plugin.refreshStatus();
      })
    );
    add("Vault path", "Absolute path to the vault (used as the working dir for runs).", "vaultPath");
    add("Commands dir", "Where the obsidian-*.md command files live.", "commandsDir");
    add("Claude binary", "Absolute path to the `claude` executable.", "claudeBin");
    add("State dir", "Where the launchd run-stamps live (default ~/.mbs_automation).", "stateDir");
    add("Reviews dir", "Vault-relative folder for weekly reviews.", "reviewsDir");
    add("Session-report dir", "Vault-relative folder for session-awareness reports.", "sessionReportDir");
  }
};
