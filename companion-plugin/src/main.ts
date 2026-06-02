/*
 * MBS Companion — v0.3.3
 * A small Obsidian plugin that surfaces the mbs_automation agents inside Obsidian:
 *   - status bar: did mbs-daily / mbs-weekly run yet? (reads the launchd run-stamps)
 *   - commands: open today's note / latest weekly review / latest session report,
 *               run the daily report or health audit headless via `claude`,
 *               cycle a Vault Agent item's status (done | skip | defer),
 *               and open a richer status panel.
 *   - on Obsidian quit: commit and push the .obsidian settings repo (v0.3.0),
 *               with a guard that refuses to auto-commit a new credential-looking file.
 *
 * Migrated to TypeScript + esbuild in v0.2.0. The build output is still main.js at
 * the plugin root (that's what Obsidian loads). Desktop-only: it uses Node's
 * fs/child_process, which Obsidian exposes to plugins on desktop.
 */

import {
  App,
  Editor,
  MarkdownView,
  Modal,
  Notice,
  Plugin,
  PluginSettingTab,
  Setting,
  TFile,
  TFolder,
} from 'obsidian';
import * as fs from 'fs';
import * as os from 'os';
import * as path from 'path';
import { exec, spawn, execSync } from 'child_process';

interface MbsSettings {
  vaultPath: string;
  commandsDir: string;
  claudeBin: string;
  stateDir: string;
  reviewsDir: string;
  sessionReportDir: string;
  pushSettingsOnQuit: boolean;
  gitBin: string;
}

const DEFAULT_SETTINGS: MbsSettings = {
  vaultPath: '/Users/cpreston/Vaults/storage_mbs',
  commandsDir: path.join(os.homedir(), '.claude', 'commands'),
  claudeBin: '/opt/homebrew/bin/claude',
  stateDir: path.join(os.homedir(), '.mbs_automation'),
  reviewsDir: 'admin/reviews',
  sessionReportDir: 'admin/obsidian_optimize/session_awareness',
  pushSettingsOnQuit: true,
  gitBin: 'git',
};

// Keys of MbsSettings whose value is a string (used by the text-field settings helper).
type StringSettingKey = {
  [K in keyof MbsSettings]: MbsSettings[K] extends string ? K : never;
}[keyof MbsSettings];

const STATUS_VALUES = ['done', 'skip', 'defer'] as const;
type StatusValue = (typeof STATUS_VALUES)[number];

function todayStr(): string {
  const d = new Date();
  const m = String(d.getMonth() + 1).padStart(2, '0');
  const day = String(d.getDate()).padStart(2, '0');
  return `${d.getFullYear()}-${m}-${day}`;
}

// ISO year-week, matching `date +%G-W%V` (computed on the local calendar date).
function isoWeekStr(): string {
  const now = new Date();
  const d = new Date(Date.UTC(now.getFullYear(), now.getMonth(), now.getDate()));
  const dayNum = (d.getUTCDay() + 6) % 7; // Mon=0 .. Sun=6
  d.setUTCDate(d.getUTCDate() - dayNum + 3); // shift to the Thursday of this ISO week
  const firstThursday = new Date(Date.UTC(d.getUTCFullYear(), 0, 4));
  const week = 1 + Math.round((d.getTime() - firstThursday.getTime()) / (7 * 86400000));
  return `${d.getUTCFullYear()}-W${String(week).padStart(2, '0')}`;
}

function readStamp(file: string): string | null {
  try {
    return fs.readFileSync(file, 'utf8').trim();
  } catch (e) {
    return null;
  }
}

// Tail the last `n` non-empty lines of a log file (mtime + content), or null if unreadable.
function readLogTail(file: string, n: number): { mtime: number; lines: string[] } | null {
  try {
    const stat = fs.statSync(file);
    const text = fs.readFileSync(file, 'utf8');
    const lines = text.split('\n').filter((l) => l.trim().length > 0);
    return { mtime: stat.mtimeMs, lines: lines.slice(-n) };
  } catch (e) {
    return null;
  }
}

export default class MbsCompanionPlugin extends Plugin {
  settings!: MbsSettings;
  statusEl: HTMLElement | null = null;

  async onload(): Promise<void> {
    await this.loadSettings();

    this.statusEl = this.addStatusBarItem();
    this.statusEl.addClass('mbs-status');
    this.registerDomEvent(this.statusEl, 'click', () => this.openDailyNote());

    this.addCommand({
      id: 'open-daily',
      name: "Open today's daily note",
      callback: () => this.openDailyNote(),
    });
    this.addCommand({
      id: 'open-weekly-review',
      name: 'Open latest weekly review',
      callback: () => this.openNewestIn(this.settings.reviewsDir),
    });
    this.addCommand({
      id: 'open-session-report',
      name: 'Open latest session-awareness report',
      callback: () => this.openNewestIn(this.settings.sessionReportDir),
    });
    this.addCommand({
      id: 'run-daily',
      name: 'Run daily report now',
      callback: () => this.runDaily(),
    });
    this.addCommand({
      id: 'run-health',
      name: 'Run health audit now',
      callback: () => this.runHealth(),
    });
    this.addCommand({
      id: 'refresh-status',
      name: 'Refresh agent status',
      callback: () => this.refreshStatus(),
    });
    this.addCommand({
      id: 'cycle-vault-agent-status',
      name: 'Cycle Vault Agent item status (done | skip | defer)',
      editorCallback: (editor: Editor, view: MarkdownView) => this.cycleVaultAgentStatus(editor),
    });
    this.addCommand({
      id: 'open-status-panel',
      name: 'Open status panel',
      callback: () => new MbsStatusModal(this.app, this).open(),
    });

    this.addSettingTab(new MbsSettingTab(this.app, this));

    // On Obsidian quit, kick off a background push of the .obsidian settings
    // repo. It runs detached and is NOT awaited, so it can never block or delay
    // shutdown (see pushSettingsRepoOnQuit).
    this.registerEvent(
      this.app.workspace.on('quit', () => this.pushSettingsRepoOnQuit()),
    );

    this.refreshStatus();
    // Re-check every 5 minutes (and registerInterval auto-clears on unload).
    this.registerInterval(window.setInterval(() => this.refreshStatus(), 5 * 60 * 1000));
  }

  async loadSettings(): Promise<void> {
    this.settings = Object.assign({}, DEFAULT_SETTINGS, await this.loadData());
  }

  async saveSettings(): Promise<void> {
    await this.saveData(this.settings);
  }

  refreshStatus(): void {
    if (!this.statusEl) return;
    const daily = readStamp(path.join(this.settings.stateDir, 'last_daily_run'));
    const weekly = readStamp(path.join(this.settings.stateDir, 'last_weekly_run'));
    const dOk = daily === todayStr();
    const wOk = weekly === isoWeekStr();
    this.statusEl.setText(`\u{1F9E0} daily ${dOk ? '✓' : '–'} · wk ${wOk ? '✓' : '–'}`);
    this.statusEl.toggleClass('mbs-pending', !dOk);
    this.statusEl.setAttribute(
      'aria-label',
      `mbs-daily last run: ${daily || 'never'} (today is ${todayStr()})\n` +
        `mbs-weekly last run: ${weekly || 'never'} (this week is ${isoWeekStr()})\n` +
        `Click to open today's note`,
    );
  }

  async openDailyNote(): Promise<void> {
    await this.openByPath(`daily_notes/tasks/tasks_${todayStr()}.md`);
  }

  async openByPath(rel: string): Promise<void> {
    const f = this.app.vault.getAbstractFileByPath(rel);
    if (f instanceof TFile) {
      await this.app.workspace.getLeaf(false).openFile(f);
    } else {
      new Notice(`MBS: not there yet — ${rel}`);
    }
  }

  async openNewestIn(relDir: string): Promise<void> {
    const f = this.newestFileIn(relDir);
    if (!f) {
      new Notice(`MBS: no usable note in ${relDir}`);
      return;
    }
    await this.app.workspace.getLeaf(false).openFile(f);
  }

  // Newest .md TFile in a vault-relative folder, or null (no notice — callers decide).
  newestFileIn(relDir: string): TFile | null {
    const folder = this.app.vault.getAbstractFileByPath(relDir);
    if (!(folder instanceof TFolder)) return null;
    const mds = folder.children.filter(
      (c): c is TFile => c instanceof TFile && c.extension === 'md',
    );
    if (!mds.length) return null;
    mds.sort((a, b) => (b.stat.mtime || 0) - (a.stat.mtime || 0));
    return mds[0];
  }

  // --- Vault Agent inline reply (v0.2.0) -----------------------------------
  // For the list item under the cursor, set/cycle its `status:` field through
  // done -> skip -> defer -> done. Only operates on lines inside a `## Vault
  // Agent` block; never touches P's own sections.
  cycleVaultAgentStatus(editor: Editor): void {
    const cursor = editor.getCursor();
    const lineCount = editor.lineCount();

    if (!this.isInsideVaultAgent(editor, cursor.line)) {
      new Notice('MBS: cursor is not inside a ## Vault Agent section');
      return;
    }

    // Find the `status:` line for the item the cursor sits on. Search downward
    // from the cursor's line to the next `status:` line, stopping at the next
    // list item (`- `) or heading so we stay within one item.
    let statusLine = -1;
    for (let i = cursor.line; i < lineCount; i++) {
      const text = editor.getLine(i);
      if (i > cursor.line && /^\s*- /.test(text)) break; // next item
      if (/^#{1,6}\s/.test(text)) break; // next heading
      if (/^\s*status:/.test(text)) {
        statusLine = i;
        break;
      }
    }
    // If not found downward, look upward in case the cursor is on the `reply:`
    // line below the status (still inside the same item).
    if (statusLine === -1) {
      for (let i = cursor.line; i >= 0; i--) {
        const text = editor.getLine(i);
        if (/^#{1,6}\s/.test(text)) break;
        if (i < cursor.line && /^\s*- /.test(text)) break;
        if (/^\s*status:/.test(text)) {
          statusLine = i;
          break;
        }
      }
    }

    if (statusLine === -1) {
      new Notice('MBS: no `status:` line found for this item');
      return;
    }

    const original = editor.getLine(statusLine);
    const indentMatch = original.match(/^(\s*)status:/);
    const indent = indentMatch ? indentMatch[1] : '    ';

    // Read the current value: anything after `status:` that is one of our
    // tokens. The placeholder `(done | skip | defer)` counts as unset.
    const current = this.parseStatus(original);
    const next = this.nextStatus(current);

    const updated = `${indent}status: ${next}`;
    editor.setLine(statusLine, updated);
    new Notice(`MBS: status -> ${next}`);
  }

  parseStatus(line: string): StatusValue | null {
    const after = line.replace(/^\s*status:\s*/, '').trim();
    for (const v of STATUS_VALUES) {
      // Match a bare token, not the `(done | skip | defer)` placeholder.
      if (after === v) return v;
    }
    return null;
  }

  nextStatus(current: StatusValue | null): StatusValue {
    if (current === null) return 'done';
    const idx = STATUS_VALUES.indexOf(current);
    return STATUS_VALUES[(idx + 1) % STATUS_VALUES.length];
  }

  // True if `line` falls under a `## Vault Agent` heading and before the next
  // heading at the same (H2) or higher level.
  isInsideVaultAgent(editor: Editor, line: number): boolean {
    let inside = false;
    for (let i = 0; i <= line; i++) {
      const text = editor.getLine(i);
      const h = text.match(/^(#{1,6})\s+(.*)$/);
      if (!h) continue;
      const level = h[1].length;
      const title = h[2].trim();
      if (level <= 2) {
        // An H1/H2 boundary: we are inside iff this very heading is Vault Agent.
        inside = level === 2 && /^vault agent\b/i.test(title);
      }
      // Deeper headings (### Overdue, etc.) don't change the section.
    }
    return inside;
  }

  // --- Headless runs -------------------------------------------------------
  runDaily(): void {
    const prompt =
      `Read ${this.settings.commandsDir}/obsidian-daily.md and carry out its instructions exactly, ` +
      `using the mbs_automation skill, against the vault at ${this.settings.vaultPath}. ` +
      `Append or refresh the bounded ## Vault Agent section in today's tasks note via the filesystem; ` +
      `do not touch P's own sections.`;
    this.runClaude(prompt, 'daily report');
  }

  runHealth(): void {
    const prompt =
      `Read ${this.settings.commandsDir}/obsidian-health.md and carry out the health audit against ` +
      `the vault at ${this.settings.vaultPath}. Report only — do not apply any fixes.`;
    this.runClaude(prompt, 'health audit');
  }

  runClaude(prompt: string, label: string): void {
    new Notice(`MBS: running ${label}… (this can take a few minutes)`);
    const env = Object.assign({}, process.env, {
      PATH: `/opt/homebrew/bin:/usr/local/bin:${path.join(os.homedir(), '.local/bin')}:${process.env.PATH || ''}`,
    });
    const cmd = `"${this.settings.claudeBin}" -p ${JSON.stringify(prompt)} --dangerously-skip-permissions`;
    exec(cmd, { cwd: this.settings.vaultPath, env, maxBuffer: 32 * 1024 * 1024 }, (err) => {
      if (err) {
        new Notice(`MBS: ${label} failed — ${err.message}`);
        return;
      }
      new Notice(`MBS: ${label} done`);
      this.refreshStatus();
    });
  }

  // --- Push settings repo on quit (v0.3.3) ---------------------------------
  // When Obsidian quits, COMMIT the .obsidian settings repo synchronously (a
  // fast local op — can't hang shutdown the way a network push can), then PUSH
  // in a detached background process that is never awaited. This guarantees the
  // commit lands the moment the handler fires (visible in `git log`), even if
  // the background push dies during app teardown. v0.3.0 awaited the whole push
  // and wedged shutdown; v0.3.1 detached everything but produced no commit.
  // Safety:
  //   - no-op if the toggle is off or there is nothing to commit,
  //   - refuses to commit when a NEW untracked file looks like a credential
  //     (token/secret/key/pem),
  //   - GIT_TERMINAL_PROMPT=0 so the push fails fast instead of hanging on auth,
  //   - every run appends a line to <stateDir>/settings_push.log for debugging.
  pushSettingsRepoOnQuit(): void {
    const logFile = path.join(this.settings.stateDir, 'settings_push.log');
    const log = (msg: string) => {
      try {
        fs.appendFileSync(logFile, `${new Date().toISOString()} ${msg}\n`);
      } catch (e) {
        /* best-effort */
      }
    };
    try {
      if (!this.settings.pushSettingsOnQuit) {
        log('skip: toggle off');
        return;
      }
      const dir = path.join(this.settings.vaultPath, this.app.vault.configDir);
      const git = this.settings.gitBin || 'git';
      const env = Object.assign({}, process.env, {
        PATH: `/opt/homebrew/bin:/usr/local/bin:/usr/bin:${process.env.PATH || ''}`,
        GIT_TERMINAL_PROMPT: '0',
      });
      const opts = { cwd: dir, env, timeout: 8000 } as const;
      log(`fired; repo=${dir}`);

      // Self-heal a stale index.lock left by an interrupted git op (force-quit,
      // crash, killed command), which would otherwise silently block the commit.
      // Only remove it if it's older than 60s — a fresh lock may belong to a real
      // concurrent git process, so leave that alone.
      const lockPath = path.join(dir, '.git', 'index.lock');
      try {
        const ageMs = Date.now() - fs.statSync(lockPath).mtimeMs;
        if (ageMs > 60000) {
          fs.unlinkSync(lockPath);
          log(`removed stale index.lock (age ${Math.round(ageMs / 1000)}s)`);
        } else {
          log(`fresh index.lock present (age ${Math.round(ageMs / 1000)}s) - leaving it`);
        }
      } catch (e) {
        /* no lock present (ENOENT) is the normal case */
      }

      const dirty = execSync(`${git} status --porcelain`, opts).toString().trim();
      if (!dirty) {
        log('no changes');
        return;
      }
      const risky = execSync(`${git} ls-files --others --exclude-standard`, opts)
        .toString()
        .split('\n')
        .filter((f) => /token|secret|credential|\.pem$|\.key$/i.test(f));
      if (risky.length) {
        log(`GUARD blocked: ${risky.join(', ')}`);
        return;
      }

      const stamp = new Date().toISOString().slice(0, 16).replace('T', ' ');
      execSync(`${git} add -A`, opts);
      execSync(`${git} commit -m ${JSON.stringify('auto: settings on shutdown ' + stamp)}`, opts);
      log('committed');

      // Push in the background so the network op never blocks shutdown.
      const child = spawn('/bin/sh', ['-c', `${git} push`], {
        cwd: dir,
        env,
        detached: true,
        stdio: 'ignore',
      });
      child.unref();
      log('push spawned');
    } catch (e) {
      log(`ERROR: ${(e as Error).message}`);
    }
  }
}

// --- Status panel modal (v0.2.0) -------------------------------------------
class MbsStatusModal extends Modal {
  plugin: MbsCompanionPlugin;

  constructor(app: App, plugin: MbsCompanionPlugin) {
    super(app);
    this.plugin = plugin;
  }

  onOpen(): void {
    const { contentEl } = this;
    const s = this.plugin.settings;
    contentEl.empty();
    contentEl.addClass('mbs-status-panel');
    contentEl.createEl('h2', { text: 'MBS Companion — status' });

    // --- Last runs (stamps + logs) ---
    const daily = readStamp(path.join(s.stateDir, 'last_daily_run'));
    const weekly = readStamp(path.join(s.stateDir, 'last_weekly_run'));
    const dOk = daily === todayStr();
    const wOk = weekly === isoWeekStr();

    const runs = contentEl.createDiv({ cls: 'mbs-section' });
    runs.createEl('h3', { text: 'Scheduled agents' });
    const dailyLog = readLogTail(path.join(s.stateDir, 'mbs_daily.log'), 1);
    const weeklyLog = readLogTail(path.join(s.stateDir, 'mbs_weekly.log'), 1);
    this.row(runs, 'mbs-daily', `${daily || 'never'} ${dOk ? '✓' : '– (today is ' + todayStr() + ')'}`);
    if (dailyLog) {
      this.subRow(runs, `log ${new Date(dailyLog.mtime).toLocaleString()}: ${dailyLog.lines[0] || ''}`);
    }
    this.row(runs, 'mbs-weekly', `${weekly || 'never'} ${wOk ? '✓' : '– (this week is ' + isoWeekStr() + ')'}`);
    if (weeklyLog) {
      this.subRow(runs, `log ${new Date(weeklyLog.mtime).toLocaleString()}: ${weeklyLog.lines[0] || ''}`);
    }

    // --- Latest session-awareness report leak count ---
    const sess = contentEl.createDiv({ cls: 'mbs-section' });
    sess.createEl('h3', { text: 'Session awareness' });
    const report = this.plugin.newestFileIn(s.sessionReportDir);
    if (report) {
      this.row(sess, 'latest report', report.basename);
      // Read the report and pull the leak count, if present.
      this.app.vault.cachedRead(report).then((text) => {
        const leaks = this.parseLeakCount(text);
        this.row(sess, 'leaks', leaks !== null ? String(leaks) : 'not stated');
      });
    } else {
      this.row(sess, 'latest report', 'none yet');
    }

    // --- Quick links ---
    const links = contentEl.createDiv({ cls: 'mbs-section' });
    links.createEl('h3', { text: 'Quick links' });
    this.link(links, "Today's daily note", () => {
      this.plugin.openDailyNote();
      this.close();
    });
    this.link(links, 'Latest weekly review', () => {
      this.plugin.openNewestIn(s.reviewsDir);
      this.close();
    });
    this.link(links, 'Latest session report', () => {
      this.plugin.openNewestIn(s.sessionReportDir);
      this.close();
    });
  }

  // Pull the leak count from a session-awareness report. Matches phrasings like
  // "Found **2 leaks**", "Found 1 leak", "**0 leaks**".
  parseLeakCount(text: string): number | null {
    const m = text.match(/(\d+)\s*\*{0,2}\s*leaks?\b/i);
    return m ? parseInt(m[1], 10) : null;
  }

  row(parent: HTMLElement, label: string, value: string): void {
    const r = parent.createDiv({ cls: 'mbs-row' });
    r.createSpan({ cls: 'mbs-label', text: label });
    r.createSpan({ cls: 'mbs-value', text: value });
  }

  subRow(parent: HTMLElement, value: string): void {
    parent.createDiv({ cls: 'mbs-subrow', text: value });
  }

  link(parent: HTMLElement, text: string, onClick: () => void): void {
    const a = parent.createEl('a', { cls: 'mbs-link', text, href: '#' });
    a.addEventListener('click', (e) => {
      e.preventDefault();
      onClick();
    });
  }

  onClose(): void {
    this.contentEl.empty();
  }
}

class MbsSettingTab extends PluginSettingTab {
  plugin: MbsCompanionPlugin;

  constructor(app: App, plugin: MbsCompanionPlugin) {
    super(app, plugin);
    this.plugin = plugin;
  }

  display(): void {
    const { containerEl } = this;
    containerEl.empty();
    containerEl.createEl('h2', { text: 'MBS Companion' });
    const add = (name: string, desc: string, key: StringSettingKey) =>
      new Setting(containerEl)
        .setName(name)
        .setDesc(desc)
        .addText((t) =>
          t.setValue(this.plugin.settings[key]).onChange(async (v) => {
            this.plugin.settings[key] = v.trim();
            await this.plugin.saveSettings();
            this.plugin.refreshStatus();
          }),
        );
    add('Vault path', 'Absolute path to the vault (used as the working dir for runs).', 'vaultPath');
    add('Commands dir', 'Where the obsidian-*.md command files live.', 'commandsDir');
    add('Claude binary', 'Absolute path to the `claude` executable.', 'claudeBin');
    add('State dir', 'Where the launchd run-stamps live (default ~/.mbs_automation).', 'stateDir');
    add('Reviews dir', 'Vault-relative folder for weekly reviews.', 'reviewsDir');
    add('Session-report dir', 'Vault-relative folder for session-awareness reports.', 'sessionReportDir');
    add('Git binary', 'Path or name of git, used to push settings on quit.', 'gitBin');
    new Setting(containerEl)
      .setName('Push settings on quit')
      .setDesc(
        'On Obsidian shutdown, commit and push the .obsidian settings repo. ' +
          'Skips automatically if a new credential-looking file (token/secret/key/pem) is present.',
      )
      .addToggle((t) =>
        t.setValue(this.plugin.settings.pushSettingsOnQuit).onChange(async (v) => {
          this.plugin.settings.pushSettingsOnQuit = v;
          await this.plugin.saveSettings();
        }),
      );
  }
}
