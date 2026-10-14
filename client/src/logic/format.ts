/**
 * Pure formatting helpers for the version and reported-health sections of the endpoint detail screen.
 */
import type {
  Endpoint,
  HealthDetailsResponse,
  HealthStatus,
  VersionHistoryResponse,
} from '../api/endpoints';

export type VersionSource = 'versionCheck' | 'healthStandard';

/**
 * Where the endpoint's version comes from, with the backend's rule (`usesAutoVersion`): the
 * health-standard response is used unless an explicit version check is enabled. A disabled
 * (paused) explicit check doesn't take over. `null` when neither applies.
 */
export function versionSourceOf(endpoint: Pick<Endpoint, 'healthStandard' | 'versionCheck'>): VersionSource | null {
  if (endpoint.healthStandard === true && endpoint.versionCheck?.isEnabled !== true) {
    return 'healthStandard';
  }
  return endpoint.versionCheck ? 'versionCheck' : null;
}

export function versionSourceLabel(source: VersionSource): string {
  return source === 'healthStandard' ? 'From health response' : 'Version check';
}

/**
 * `1.4.2` → `v1.4.2`. Only version-number-looking values get the prefix; anything else (`v2`,
 * `main@9f2c`, a bare commit SHA like `9f2c1ab`) is shown as is.
 */
export function formatVersion(value: string | null | undefined): string {
  const trimmed = value?.trim();
  if (!trimmed) return '—';
  return /^\d+(\.\d|$|\s)/.test(trimmed) ? `v${trimmed}` : trimmed;
}

export function formatDateTime(iso: string | null | undefined): string {
  if (!iso) return '—';
  const date = new Date(iso);
  return Number.isNaN(date.getTime()) ? '—' : date.toLocaleString();
}

export interface VersionStatusText {
  /** Short state, e.g. "OK", "Failing", "Paused", "Not checked yet". */
  label: string;
  tone: 'ok' | 'failing' | 'muted';
  /** Failure reason, only when failing. */
  detail: string | null;
}

/**
 * State line of the version section. A paused explicit check says so (its last result may be
 * stale); otherwise failing wins, then "not checked yet" until a first result exists.
 */
export function versionStatusText(
  current: VersionHistoryResponse['current'],
  options: { source: VersionSource | null; isEnabled: boolean },
): VersionStatusText {
  if (options.source === 'versionCheck' && !options.isEnabled) {
    return { label: 'Paused', tone: 'muted', detail: null };
  }
  if (!current) {
    return { label: 'Not checked yet', tone: 'muted', detail: null };
  }
  if (current.isFailing) {
    return { label: 'Failing', tone: 'failing', detail: current.failureReason ?? 'Version check failed' };
  }
  return { label: 'OK', tone: 'ok', detail: null };
}

/** Newest first by `firstSeenAt`. The backend already sorts; this keeps the UI correct regardless. */
export function sortVersionHistory(history: VersionHistoryResponse['history']): VersionHistoryResponse['history'] {
  return history
    .slice()
    .sort((a, b) => new Date(b.firstSeenAt).getTime() - new Date(a.firstSeenAt).getTime());
}

/** "first seen – last seen", collapsing to one timestamp when they're equal. */
export function formatSeenRange(entry: { firstSeenAt: string; lastSeenAt: string }): string {
  const first = formatDateTime(entry.firstSeenAt);
  const last = formatDateTime(entry.lastSeenAt);
  return first === last ? first : `${first} – ${last}`;
}

export function healthStatusLabel(status: HealthStatus): string {
  if (status === 'pass') return 'Pass';
  if (status === 'warn') return 'Warn';
  return 'Fail';
}

/** Reported-health section: shown for health-standard endpoints, or whenever a report was recorded. */
export function shouldShowHealthReport(
  details: HealthDetailsResponse | null,
  endpoint: Pick<Endpoint, 'healthStandard'>,
): boolean {
  return endpoint.healthStandard === true || details?.healthStandard === true || details?.latest != null;
}

/** Version section: shown when a source applies or there's recorded history. */
export function shouldShowVersion(
  versions: VersionHistoryResponse | null,
  source: VersionSource | null,
): boolean {
  return source !== null || (versions?.history.length ?? 0) > 0 || versions?.current != null;
}
