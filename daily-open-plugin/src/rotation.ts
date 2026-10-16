/*
 * v0.1.6: which stale daily-note tabs may be closed.
 *
 * Pure (no Obsidian import) so `npm test` can run it under plain node.
 *
 * A stale tab is closed only when its OWN journal's note for today exists.
 * Before 0.1.6 the rotate loop closed every stale tab of every journal whenever
 * openDailies ran, so the health note appearing just after midnight (Journals
 * autoCreate on garm) closed the tab on yesterday's tasks note hours before
 * today's tasks note existed, leaving P with no tasks tab at all.
 */

export interface RotationSpec {
  todayPath: string; // this journal's note path for today
  pathRe: RegExp; // matches this journal's note for ANY date
}

// openPaths: paths of every open daily-note-ish leaf (one entry per path).
// todayExists: today paths whose note is open or was found as a file this run.
// Returns the open paths whose leaves should be detached.
export function stalePathsToDetach(
  openPaths: Iterable<string>,
  specs: RotationSpec[],
  todayExists: Set<string>,
): string[] {
  const todayPaths = new Set(specs.map((s) => s.todayPath));
  const out: string[] = [];
  for (const p of openPaths) {
    if (todayPaths.has(p)) continue;
    const owner = specs.find((s) => s.pathRe.test(p));
    if (!owner) continue;
    if (todayExists.has(owner.todayPath)) out.push(p);
  }
  return out;
}
