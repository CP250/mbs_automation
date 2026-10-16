/*
 * Daily Auto-Open: v0.1.6
 * Opens today's daily notes (e.g. health + tasks) when Obsidian launches, on
 * desktop and mobile. Optional: pin them as persistent tabs, and rotate (close
 * previous days' daily-note tabs so only today's stay open).
 *
 * v0.1.6 rotates a journal's stale tabs only once that journal's note for
 * today exists (see src/rotation.ts). Before, any today-note creation (the
 * health note just after midnight) closed every journal's stale tabs, so the
 * tab on yesterday's tasks note vanished hours before today's tasks note was
 * made.
 *
 * v0.1.5 adds layout-resilient column targeting via `preferredPositions`. Each
 * spec can declare `'leftmost'` or `'rightmost'` instead of (or in addition to)
 * a workspace-UUID `preferredParentId`. Positions resolve to the actual pane at
 * runtime by walking the main root-split children, so they survive workspace
 * rebuilds and saved-workspace loads — UUIDs do not. The placement priority is
 * now FOUR-tier:
 *   1. A `preferredPositions[spec.name]` is set -> resolve leftmost/rightmost
 *      main-split tabs container at runtime and place today's note there.
 *   2. A stale tab is present for this spec -> use its parent.
 *   3. A saved `preferredParentIds[spec.name]` matches an existing pane -> use it.
 *   4. None of the above -> active pane.
 * When positions are set, the auto-learned UUID is NOT overwritten — explicit
 * intent stays canonical. When positions are absent, existing auto-learn behavior
 * applies (drag-to-relearn).
 *
 * v0.1.4 persists the parent-pane id for each spec into data.json after each
 * successful open (three-tier fallback: stale -> saved id -> active).
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
import { stalePathsToDetach } from './rotation';

interface NoteSpec {
  name: string;
  folder: string;
  filename: string; // contains {{date}}
  dateFormat: string; // e.g. YYYY-MM-DD
}

type EdgePosition = 'leftmost' | 'rightmost';

interface DAOSettings {
  openOnStartup: boolean;
  pinTabs: boolean;
  rotateStale: boolean;
  startupDelayMs: number;
  notes: NoteSpec[];
  preferredParentIds?: Record<string, string>; // v0.1.4: spec.name -> parent pane id (auto-learned, UUID)
  preferredPositions?: Record<string, EdgePosition>; // v0.1.5: spec.name -> 'leftmost' | 'rightmost' (durable, layout-resilient)
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
  preferredPositions: {},
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

  // v0.1.5: resolve a directional position ('leftmost' | 'rightmost') to the id
  // of the tabs container at that edge of the main root split, at runtime. This
  // survives workspace rebuilds because we walk the live layout instead of
  // remembering a UUID. If the edge child is itself a split (nested layout), we
  // descend along the same edge until we hit a tabs container.
  edgeTabsId(position: EdgePosition): string | undefined {
    const root = (this.app.workspace as unknown as { rootSplit?: { children?: unknown[] } }).rootSplit;
    if (!root || !Array.isArray(root.children) || root.children.length === 0) return undefined;
    const pickEdge = (arr: unknown[]): unknown => (position === 'leftmost' ? arr[0] : arr[arr.length - 1]);
    let node: unknown = pickEdge(root.children);
    // Descend into nested splits, always taking the same edge.
    // Guard against runaway recursion with a hard ceiling.
    for (let depth = 0; depth < 16; depth++) {
      if (!node) return undefined;
      const n = node as { type?: string; id?: string; children?: unknown[] };
      // Treat 'tabs' (or anything without a recognized 'split' type) as terminal.
      if (n.type === 'tabs') return n.id;
      if (!Array.isArray(n.children) || n.children.length === 0) return n.id;
      // If this node has children and isn't tabs, treat as a split and descend.
      if (n.type === 'split') {
        node = pickEdge(n.children);
        continue;
      }
      // Unknown container type with children: assume split-like and descend.
      node = pickEdge(n.children);
    }
    return undefined;
  }

  // v0.1.5: find any leaf whose parent matches the given tabs container id.
  // Used to setActiveLeaf so getLeaf('tab') opens in the same parent.
  findLeafByParentId(parentId: string): WorkspaceLeaf | undefined {
    let found: WorkspaceLeaf | undefined;
    this.app.workspace.iterateAllLeaves((leaf) => {
      if (found) return;
      const pid = (leaf as unknown as { parent?: { id?: string } }).parent?.id;
      if (pid === parentId) found = leaf;
    });
    return found;
  }

  async openDailies(): Promise<void> {
    const specs = this.settings.notes;
    const todayByPath = new Map<string, NoteSpec>();
    specs.forEach((s) => todayByPath.set(this.todayPath(s), s));

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
    //    Column placement priority (v0.1.5):
    //      a) preferredPositions[spec.name] set -> resolve 'leftmost'/'rightmost'
    //         against the live main root split (layout-resilient; explicit intent).
    //      b) stale tab present for this spec -> use its parent (v0.1.3 logic).
    //      c) no stale tab, but saved parent id matches an existing pane -> use it (v0.1.4).
    //      d) none of the above -> active pane fallback.
    //    When (a) wins, the auto-learned preferredParentIds[spec.name] is NOT
    //    overwritten — explicit intent stays canonical across drags.
    let missing = 0;
    let settingsDirty = false;
    const todayExists = new Set<string>(); // v0.1.6: today paths open or found this run
    for (const [path, spec] of todayByPath.entries()) {
      const existing = byPath.get(path) || [];
      let keep: WorkspaceLeaf | null = existing[0] || null;
      existing.slice(1).forEach((l) => l.detach()); // close duplicate copies of today's note
      const position = this.settings.preferredPositions?.[spec.name];
      if (!keep) {
        const af = this.app.vault.getAbstractFileByPath(path);
        if (!(af instanceof TFile)) {
          missing++;
          continue;
        }
        let placed = false;
        // Tier (a): explicit position wins. Resolve to live tabs id, find a leaf
        // there, activate it so getLeaf('tab') opens in that container.
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
        // Tier (b): stale tab present -> activate so getLeaf('tab') uses its parent.
        if (!placed) {
          const staleLeaves = staleBySpec.get(path) || [];
          if (staleLeaves.length > 0) {
            this.app.workspace.setActiveLeaf(staleLeaves[0], { focus: false });
            placed = true;
          }
        }
        // Tier (c): persisted parent id from a prior run (auto-learned UUID).
        if (!placed) {
          const savedId = this.settings.preferredParentIds?.[spec.name];
          if (savedId) {
            const target = this.findLeafByParentId(savedId);
            if (target) {
              this.app.workspace.setActiveLeaf(target, { focus: false });
              placed = true;
            }
          }
        }
        // Tier (d): falls through to active-pane default (getLeaf('tab') uses it).
        keep = this.app.workspace.getLeaf('tab');
        await keep.openFile(af, { active: false });
        // Persist where today's note landed — but ONLY if no explicit position is
        // set for this spec. With a position, the UUID is irrelevant: position wins
        // every run, and we don't want a drag-and-drop to silently override intent.
        if (!position) {
          const newParentId = (keep as unknown as { parent?: { id?: string } }).parent?.id;
          if (newParentId) {
            if (!this.settings.preferredParentIds) this.settings.preferredParentIds = {};
            if (this.settings.preferredParentIds[spec.name] !== newParentId) {
              this.settings.preferredParentIds[spec.name] = newParentId;
              settingsDirty = true;
            }
          }
        }
      }
      if (keep) todayExists.add(path);
      if (this.settings.pinTabs && keep) {
        (keep as unknown as { setPinned?: (p: boolean) => void }).setPinned?.(true);
      }
    }
    if (settingsDirty) await this.saveSettings();

    // 2. Rotate (detach) stale leaves AFTER today's notes are placed in the
    //    correct panes. Detaching afterward avoids leaving a parent momentarily
    //    empty, which can cause Obsidian to collapse the pane.
    //    v0.1.6: only a journal whose note for today exists loses its stale tabs.
    if (this.settings.rotateStale) {
      const rotationSpecs = specs.map((s) => ({ todayPath: this.todayPath(s), pathRe: this.specPathRe(s) }));
      for (const p of stalePathsToDetach(byPath.keys(), rotationSpecs, todayExists)) {
        (byPath.get(p) || []).forEach((l) => l.detach());
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
      // v0.1.5: directional position picker. Overrides UUID auto-learning.
      s.addDropdown((d) => {
        d.addOption('', 'auto (drag-to-learn)');
        d.addOption('leftmost', 'leftmost pane');
        d.addOption('rightmost', 'rightmost pane');
        const current = this.plugin.settings.preferredPositions?.[spec.name] ?? '';
        d.setValue(current);
        d.onChange(async (v) => {
          if (!this.plugin.settings.preferredPositions) this.plugin.settings.preferredPositions = {};
          if (v === '') {
            delete this.plugin.settings.preferredPositions[spec.name];
          } else {
            this.plugin.settings.preferredPositions[spec.name] = v as EdgePosition;
          }
          await this.plugin.saveSettings();
        });
      });
    });

    containerEl.createEl('p', {
      text: 'Position picker (v0.1.5): "auto" preserves prior behavior (auto-learns from drags via UUID). "leftmost"/"rightmost" resolve to the actual edge pane of the main split at runtime — survives workspace rebuilds and saved-workspace loads.',
      cls: 'setting-item-description',
    });
  }
}
