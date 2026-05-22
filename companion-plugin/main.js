'use strict';

/*
 * MBS Companion — v0.1.0
 * A small Obsidian plugin that surfaces the mbs_automation agents inside Obsidian:
 *   - status bar: did mbs-daily / mbs-weekly run yet? (reads the launchd run-stamps)
 *   - commands: open today's note / latest weekly review / latest session report,
 *               and run the daily report or health audit headless via `claude`.
 *
 * Shipped as plain JS (no build step) so it loads directly. Desktop-only: it uses
 * Node's fs/child_process, which Obsidian exposes to plugins on desktop.
 */

const { Plugin, PluginSettingTab, Setting, Notice, TFolder, TFile } = require('obsidian');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { exec } = require('child_process');

const DEFAULT_SETTINGS = {
  vaultPath: '/Users/cpreston/Vaults/storage_mbs',
  commandsDir: path.join(os.homedir(), '.claude', 'commands'),
  claudeBin: '/opt/homebrew/bin/claude',
  stateDir: path.join(os.homedir(), '.mbs_automation'),
  reviewsDir: 'admin/reviews',
  sessionReportDir: 'admin/obsidian_optimize/session_awareness',
};

function todayStr() {
  const d = new Date();
  const m = String(d.getMonth() + 1).padStart(2, '0');
  const day = String(d.getDate()).padStart(2, '0');
  return `${d.getFullYear()}-${m}-${day}`;
}

// ISO year-week, matching `date +%G-W%V` (computed on the local calendar date).
function isoWeekStr() {
  const now = new Date();
  const d = new Date(Date.UTC(now.getFullYear(), now.getMonth(), now.getDate()));
  const dayNum = (d.getUTCDay() + 6) % 7; // Mon=0 .. Sun=6
  d.setUTCDate(d.getUTCDate() - dayNum + 3); // shift to the Thursday of this ISO week
  const firstThursday = new Date(Date.UTC(d.getUTCFullYear(), 0, 4));
  const week = 1 + Math.round((d - firstThursday) / (7 * 86400000));
  return `${d.getUTCFullYear()}-W${String(week).padStart(2, '0')}`;
}

function readStamp(file) {
  try { return fs.readFileSync(file, 'utf8').trim(); } catch (e) { return null; }
}

class MbsCompanionPlugin extends Plugin {
  async onload() {
    await this.loadSettings();

    this.statusEl = this.addStatusBarItem();
    this.statusEl.addClass('mbs-status');
    this.registerDomEvent(this.statusEl, 'click', () => this.openDailyNote());

    this.addCommand({ id: 'open-daily', name: "Open today's daily note", callback: () => this.openDailyNote() });
    this.addCommand({ id: 'open-weekly-review', name: 'Open latest weekly review', callback: () => this.openNewestIn(this.settings.reviewsDir) });
    this.addCommand({ id: 'open-session-report', name: 'Open latest session-awareness report', callback: () => this.openNewestIn(this.settings.sessionReportDir) });
    this.addCommand({ id: 'run-daily', name: 'Run daily report now', callback: () => this.runDaily() });
    this.addCommand({ id: 'run-health', name: 'Run health audit now', callback: () => this.runHealth() });
    this.addCommand({ id: 'refresh-status', name: 'Refresh agent status', callback: () => this.refreshStatus() });

    this.addSettingTab(new MbsSettingTab(this.app, this));

    this.refreshStatus();
    // Re-check every 5 minutes (and registerInterval auto-clears on unload).
    this.registerInterval(window.setInterval(() => this.refreshStatus(), 5 * 60 * 1000));
  }

  async loadSettings() { this.settings = Object.assign({}, DEFAULT_SETTINGS, await this.loadData()); }
  async saveSettings() { await this.saveData(this.settings); }

  refreshStatus() {
    if (!this.statusEl) return;
    const daily = readStamp(path.join(this.settings.stateDir, 'last_daily_run'));
    const weekly = readStamp(path.join(this.settings.stateDir, 'last_weekly_run'));
    const dOk = daily === todayStr();
    const wOk = weekly === isoWeekStr();
    this.statusEl.setText(`\u{1F9E0} daily ${dOk ? '✓' : '–'} · wk ${wOk ? '✓' : '–'}`);
    this.statusEl.toggleClass('mbs-pending', !dOk);
    this.statusEl.setAttribute('aria-label',
      `mbs-daily last run: ${daily || 'never'} (today is ${todayStr()})\n` +
      `mbs-weekly last run: ${weekly || 'never'} (this week is ${isoWeekStr()})\n` +
      `Click to open today's note`);
  }

  async openDailyNote() {
    await this.openByPath(`daily_notes/tasks/tasks_${todayStr()}.md`);
  }

  async openByPath(rel) {
    const f = this.app.vault.getAbstractFileByPath(rel);
    if (f instanceof TFile) {
      await this.app.workspace.getLeaf(false).openFile(f);
    } else {
      new Notice(`MBS: not there yet — ${rel}`);
    }
  }

  async openNewestIn(relDir) {
    const folder = this.app.vault.getAbstractFileByPath(relDir);
    if (!(folder instanceof TFolder)) { new Notice(`MBS: no ${relDir} folder yet`); return; }
    const mds = folder.children.filter((c) => c instanceof TFile && c.extension === 'md');
    if (!mds.length) { new Notice(`MBS: ${relDir} is empty`); return; }
    mds.sort((a, b) => (b.stat.mtime || 0) - (a.stat.mtime || 0));
    await this.app.workspace.getLeaf(false).openFile(mds[0]);
  }

  runDaily() {
    const prompt = `Read ${this.settings.commandsDir}/obsidian-daily.md and carry out its instructions exactly, using the mbs_automation skill, against the vault at ${this.settings.vaultPath}. Append or refresh the bounded ## Vault Agent section in today's tasks note via the filesystem; do not touch P's own sections.`;
    this.runClaude(prompt, 'daily report');
  }

  runHealth() {
    const prompt = `Read ${this.settings.commandsDir}/obsidian-health.md and carry out the health audit against the vault at ${this.settings.vaultPath}. Report only — do not apply any fixes.`;
    this.runClaude(prompt, 'health audit');
  }

  runClaude(prompt, label) {
    new Notice(`MBS: running ${label}… (this can take a few minutes)`);
    const env = Object.assign({}, process.env, {
      PATH: `/opt/homebrew/bin:/usr/local/bin:${path.join(os.homedir(), '.local/bin')}:${process.env.PATH || ''}`,
    });
    const cmd = `"${this.settings.claudeBin}" -p ${JSON.stringify(prompt)} --dangerously-skip-permissions`;
    exec(cmd, { cwd: this.settings.vaultPath, env, maxBuffer: 32 * 1024 * 1024 }, (err) => {
      if (err) { new Notice(`MBS: ${label} failed — ${err.message}`); return; }
      new Notice(`MBS: ${label} done`);
      this.refreshStatus();
    });
  }
}

class MbsSettingTab extends PluginSettingTab {
  constructor(app, plugin) { super(app, plugin); this.plugin = plugin; }
  display() {
    const { containerEl } = this;
    containerEl.empty();
    containerEl.createEl('h2', { text: 'MBS Companion' });
    const add = (name, desc, key) =>
      new Setting(containerEl).setName(name).setDesc(desc).addText((t) =>
        t.setValue(this.plugin.settings[key]).onChange(async (v) => {
          this.plugin.settings[key] = v.trim();
          await this.plugin.saveSettings();
          this.plugin.refreshStatus();
        }));
    add('Vault path', 'Absolute path to the vault (used as the working dir for runs).', 'vaultPath');
    add('Commands dir', 'Where the obsidian-*.md command files live.', 'commandsDir');
    add('Claude binary', 'Absolute path to the `claude` executable.', 'claudeBin');
    add('State dir', 'Where the launchd run-stamps live (default ~/.mbs_automation).', 'stateDir');
    add('Reviews dir', 'Vault-relative folder for weekly reviews.', 'reviewsDir');
    add('Session-report dir', 'Vault-relative folder for session-awareness reports.', 'sessionReportDir');
  }
}

module.exports = MbsCompanionPlugin;
