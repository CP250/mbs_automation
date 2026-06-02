/*
 * Daily Auto-Open — v0.1.4
 * Opens today's daily notes (e.g. health + tasks) when Obsidian launches, on
 * desktop and mobile. Optional: pin them as persistent tabs, and rotate (close
 * previous days' daily-note tabs so only today's stay open).
 *
 * v0.1.4 persists the parent-pane id for each spec into data.json after each
 * successful open. The column-placement lookup is now three-tier:
 *   1. A stale tab is present → use its parent (v0.1.3's logic; wins normally)
 *   2. No stale tab, but a saved parent id matches an existing pane → use it
 *   3. Neither → fall back to the active pane
 * This means today's notes still land in the same column even if the previously
 * pinned daily tabs got closed before launch (rare but possible). The saved id
 * is refreshed every successful open, so dragging the daily notes to a different
 * column auto-learns on the next run.
 *
 * v0.1.3 made column placement deterministic via stale-parent capture: when
 * rotating, the plugin remembers which parent pane held each spec's previous-day
 * leaf, opens today's note in that SAME parent, and only then detaches stale.
 *
 * v0.1.2 added event-driven retry: in addition to the startup-delay run, the
 * plugin listens for vault file-creation events and re-runs openDailies when a
 * today-matching path appears.
 *
 * Cross-platform: uses only the Obsidian workspace API (no Node), so unlike the
 * MBS Companion plugin it is NOT desktop-only and runs on iPhone too.
 */

import {
  App,
  Notice,
  Plugin,
  PluginSettingTab,
  Setting,
  TFile,
  WorkspaceLeaf,
  normalizePath,
} from 'obsidian';

interface NoteSpec {
  name: string;
  folder: string;
  filename: string; // contains {{date}}
  dateFormat: string; // e.g. YYYY-MM-DD
}

interface DAOSettings {
  openOnStartup: boolean;
  pinTabs: boolean;
  rotateStale: boolean;
  startupDelayMs: number;
  notes: NoteSpec[];
  preferredParentIds?: Record<string, string>; // v0.1.4: spec.name -> parent pane id
}

const DEFAULT_SETTINGS: DAOSettings = {
  openOnStartup: true,
  pinTabs: true,
  rotateStale: true,
  startupDelayMs: 1200,
  notes: [
    { name: 'health', folder: 'daily_notes/health/daily', filename: 'daily_note_health_{{date}}', dateFormat: 'YYYY-MM-DD' },
    { name: 'tasks', folder: 'daily_notes/tasks', filename: 'tasks_{{date}}', dateFormat: 'YYYY-MM-DD' },
  ],
  preferredParentIds: {},
};

function escapeRe(s: string): string {
  return s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

// Build a regex fragment that matches any date in this format (YYYY/MM/DD tokens).
function dateTokenRe(fmt: string): string {
  return escapeRe(fmt).replace(/YYYY/g, '\\d{4}').replace(/MM/g, '\\d{2}').replace(/DD/g, '\\d{2}');
}

function formatToday(fmt: string): string {
  const d = new Date();
  const yyyy = String(d.getFullYear());
  const mm = String(d.getMonth() + 1).padStart(2, '0');
  const dd = String(d.getDate()).padStart(2, '0');
  return fmt.replace(/YYYY/g, yyyy).replace(/MM/g, mm).replace(/DD/g, dd);
}

export default class DailyAutoOpenPlugin extends Plugin {
  settings!: DAOSettings;

  async onload(): Promise<void> {
    await this.loadSettings();
    this.addSettingTab(new DAOSettingTab(this.app, this));

    this.addCommand({
      id: 'open-todays-dailies',
      name: "Open today's daily notes",
      callback: () => this.openDailies(),
    });

    this.app.workspace.onLayoutReady(() => {
      if (!this.settings.openOnStartup) return;
      // Delay so the Journals plugin can auto-create today's notes first.
      window.setTimeout(() => this.openDailies(), Math.max(0, this.settings.startupDelayMs));
    });

    // v0.1.2: event-driven retry. If Journals/Templater finishes creating a
    // today-matching note after our startup delay (or at any other point), we
    // catch the 'create' event and run openDailies. Cheap gate: only react if
    // the created path equals one of today's expected note paths.
    this.registerEvent(
      this.app.vault.on('create', (file) => {
        if (!(file instanceof TFile)) return;
        if (!this.settings.openOnStartup) return;
        const todayPaths = new Set(this.settings.notes.map((s) => this.todayPath(s)));
        if (todayPaths.has(file.path)) {
          // Small debounce so Templater finishes its pass before we open.
          window.setTimeout(() => this.openDailies(), 250);
        }
      }),
    );
  }

  todayPath(spec: NoteSpec): string {
    const stamp = formatToday(spec.dateFormat || 'YYYY-MM-DD');
    const fname = spec.filename.replace(/\{\{date\}\}/g, stamp);
    return normalizePath(`${spec.folder}/${fname}.md`);
  }

  // Regex matching this spec's notes for ANY date (used to find stale tabs).
  specPathRe(spec: NoteSpec): RegExp {
    const folder = spec.folder.replace(/^\/+|\/+$/g, '');
    const parts = spec.filename.split('{{date}}').map(escapeRe);
    const fnameRe = parts.join(dateTokenRe(spec.dateFormat || 'YYYY-MM-DD'));
    return new RegExp('^' + escapeRe(folder) + '/' + fnameRe + '\\.md$');
  }

  // File path of a leaf — read from view STATE so it works even for deferred
  // (lazy, not-yet-loaded) restored tabs, where leaf.view.file is undefined.
  leafPath(leaf: WorkspaceLeaf): string | undefined {
    const st = leaf.getViewState();
    const sf = st && st.state ? (st.state as { file?: unknown }).file : undefined;
    if (typeof sf === 'string' && sf) return sf;
    const vf = (leaf.view as { file?: TFile } | undefined)?.file;
    return vf?.path;
  }

  async openDailies(): Promise<void> {
    const specs = this.settings.notes;
    const todayByPath = new Map<string, NoteSpec>();
    specs.forEach((s) => todayByPath.set(this.todayPath(s), s));
    const regexes = specs.map((s) => this.specPathRe(s));

    // Index every open leaf by its file path (deferred-tab safe).
    const byPath = new Map<string, WorkspaceLeaf[]>();
    this.app.workspace.iterateAllLeaves((leaf) => {
      const p = this.leafPath(leaf);
      if (!p) return;
      const arr = byPath.get(p) || [];
      arr.push(leaf);
      byPath.set(p, arr);
    });

    // v0.1.3: collect stale leaves grouped by spec.todayPath() so we know which
    // parent pane held each spec's previous-day note. This lets us open today's
    // note in the SAME column rather than wherever happens to be active.
    const staleBySpec = new Map<string, WorkspaceLeaf[]>();
    for (const [p, leaves] of byPath) {
      if (todayByPath.has(p)) continue; // not stale — already today's
      for (const spec of specs) {
        if (this.specPathRe(spec).test(p)) {
          const tp = this.todayPath(spec);
          const arr = staleBySpec.get(tp) || [];
          arr.push(...leaves);
          staleBySpec.set(tp, arr);
        }
      }
    }

    // 1. For each of today's notes: de-dupe, open if missing in the right parent
    //    pane, pin. Open BEFORE detaching stale so the parent pane doesn't
    //    briefly become empty (which can collapse it).
    //    Column placement priority (v0.1.4):
    //      a) stale tab present for this spec -> use its parent
    //      b) no stale tab, but saved parent id matches an existing pane -> use it
    //      c) neither -> active pane fallback
    let missing = 0;
    let settingsDirty = false;
    for (const [path, spec] of todayByPath.entries()) {
      const existing = byPath.get(path) || [];
      let keep: WorkspaceLeaf | null = existing[0] || null;
      existing.slice(1).forEach((l) => l.detach()); // close duplicate copies of today's note
      if (!keep) {
        const af = this.app.vault.getAbstractFileByPath(path);
        if (!(af instanceof TFile)) {
          missing++;
          continue;
        }
        // Tier (a): stale tab present -> activate so getLeaf('tab') uses its parent.
        const staleLeaves = staleBySpec.get(path) || [];
        if (staleLeaves.length > 0) {
          this.app.workspace.setActiveLeaf(staleLeaves[0], { focus: false });
        } else {
          // Tier (b): no stale tab — try the persisted parent id from a prior run.
          const savedId = this.settings.preferredParentIds?.[spec.name];
          if (savedId) {
            let target: WorkspaceLeaf | undefined;
            this.app.workspace.iterateAllLeaves((leaf) => {
              if (target) return;
              const pid = (leaf as unknown as { parent?: { id?: string } }).parent?.id;
              if (pid === savedId) target = leaf;
            });
            if (target) this.app.workspace.setActiveLeaf(target, { focus: false });
          }
        }
        keep = this.app.workspace.getLeaf('tab');
        await keep.openFile(af, { active: false });
        // v0.1.4: persist where today's note actually landed, so future launches
        // can find the same column even if pinned tabs have been closed.
        const newParentId = (keep as unknown as { parent?: { id?: string } }).parent?.id;
        if (newParentId) {
          if (!this.settings.preferredParentIds) this.settings.preferredParentIds = {};
          if (this.settings.preferredParentIds[spec.name] !== newParentId) {
            this.settings.preferredParentIds[spec.name] = newParentId;
            settingsDirty = true;
          }
        }
      }
      if (this.settings.pinTabs && keep) {
        (keep as unknown as { setPinned?: (p: boolean) => void }).setPinned?.(true);
      }
    }
    if (settingsDirty) await this.saveSettings();

    // 2. Rotate (detach) stale leaves AFTER today's notes are placed in the
    //    correct panes. Detaching afterward avoids leaving a parent momentarily
    //    empty, which can cause Obsidian to collapse the pane.
    if (this.settings.rotateStale) {
      for (const [p, leaves] of byPath) {
        if (todayByPath.has(p)) continue;
        if (regexes.some((r) => r.test(p))) leaves.forEach((l) => l.detach());
      }
    }

    if (missing > 0) {
      new Notice(`Daily Auto-Open: ${missing} of today's notes not found yet — they'll open once created.`);
    }
  }

  async loadSettings(): Promise<void> {
    this.settings = Object.assign({}, DEFAULT_SETTINGS, await this.loadData());
  }

  async saveSettings(): Promise<void> {
    await this.saveData(this.settings);
  }
}

class DAOSettingTab extends PluginSettingTab {
  plugin: DailyAutoOpenPlugin;

  constructor(app: App, plugin: DailyAutoOpenPlugin) {
    super(app, plugin);
    this.plugin = plugin;
  }

  display(): void {
    const { containerEl } = this;
    containerEl.empty();
    containerEl.createEl('h2', { text: 'Daily Auto-Open' });

    new Setting(containerEl)
      .setName('Open on startup')
      .setDesc("Open today's daily notes automatically when Obsidian launches.")
      .addToggle((t) =>
        t.setValue(this.plugin.settings.openOnStartup).onChange(async (v) => {
          this.plugin.settings.openOnStartup = v;
          await this.plugin.saveSettings();
        }),
      );

    new Setting(containerEl)
      .setName('Pin as tabs')
      .setDesc('Keep the opened notes pinned so they persist as tabs (desktop) / stay open (mobile).')
      .addToggle((t) =>
        t.setValue(this.plugin.settings.pinTabs).onChange(async (v) => {
          this.plugin.settings.pinTabs = v;
          await this.plugin.saveSettings();
        }),
      );

    new Setting(containerEl)
      .setName('Rotate stale tabs')
      .setDesc("On open, close previous days' daily-note tabs so only today's stay open.")
      .addToggle((t) =>
        t.setValue(this.plugin.settings.rotateStale).onChange(async (v) => {
          this.plugin.settings.rotateStale = v;
          await this.plugin.saveSettings();
        }),
      );

    new Setting(containerEl)
      .setName('Startup delay (ms)')
      .setDesc("Wait this long after launch before opening, so the Journals plugin can create today's notes first.")
      .addText((t) =>
        t.setValue(String(this.plugin.settings.startupDelayMs)).onChange(async (v) => {
          const n = parseInt(v, 10);
          this.plugin.settings.startupDelayMs = isNaN(n) ? 1200 : n;
          await this.plugin.saveSettings();
        }),
      );

    containerEl.createEl('h3', { text: 'Notes opened each day' });
    containerEl.createEl('p', {
      text: 'Each note: folder + filename (use {{date}}) + date format. Defaults match your Journals health + tasks notes.',
      cls: 'setting-item-description',
    });
    this.plugin.settings.notes.forEach((spec, i) => {
      const s = new Setting(containerEl).setName(spec.name || `note ${i + 1}`);
      s.addText((t) =>
        t.setPlaceholder('folder').setValue(spec.folder).onChange(async (v) => {
          spec.folder = v.trim();
          await this.plugin.saveSettings();
        }),
      );
      s.addText((t) =>
        t.setPlaceholder('filename_{{date}}').setValue(spec.filename).onChange(async (v) => {
          spec.filename = v.trim();
          await this.plugin.saveSettings();
        }),
      );
    });
  }
}
