import { test } from 'node:test';
import assert from 'node:assert/strict';
import { stalePathsToDetach, type RotationSpec } from '../src/rotation.ts';

const H_TODAY = 'daily_notes/health/daily/daily_note_health_2026-10-17.md';
const H_OLD = 'daily_notes/health/daily/daily_note_health_2026-10-16.md';
const T_TODAY = 'daily_notes/tasks/tasks_2026-10-17.md';
const T_OLD = 'daily_notes/tasks/tasks_2026-10-16.md';
const OTHER = 'admin/dashboard_places.md';

const specs: RotationSpec[] = [
  { todayPath: H_TODAY, pathRe: /^daily_notes\/health\/daily\/daily_note_health_\d{4}-\d{2}-\d{2}\.md$/ },
  { todayPath: T_TODAY, pathRe: /^daily_notes\/tasks\/tasks_\d{4}-\d{2}-\d{2}\.md$/ },
];

const open = [H_OLD, T_OLD, OTHER];

test('health today present, tasks today missing: only the health tab is detached', () => {
  assert.deepEqual(stalePathsToDetach([...open, H_TODAY], specs, new Set([H_TODAY])), [H_OLD]);
});

test('both present: both stale tabs detached', () => {
  assert.deepEqual(stalePathsToDetach([...open, H_TODAY, T_TODAY], specs, new Set([H_TODAY, T_TODAY])).sort(), [H_OLD, T_OLD].sort());
});

test('neither present: nothing detached', () => {
  assert.deepEqual(stalePathsToDetach(open, specs, new Set()), []);
});

test('tasks present, health missing: only the tasks tab detached', () => {
  assert.deepEqual(stalePathsToDetach([...open, T_TODAY], specs, new Set([T_TODAY])), [T_OLD]);
});

test('today paths and non-journal paths are never detached', () => {
  const out = stalePathsToDetach([H_TODAY, T_TODAY, OTHER], specs, new Set([H_TODAY, T_TODAY]));
  assert.deepEqual(out, []);
});
