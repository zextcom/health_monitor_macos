/**
 * Pure state, validation and payload building for the add/edit endpoint form. Mirrors the macOS
 * `EndpointFormView` / `VersionCheckDraft` semantics, within the backend's validation limits
 * (backend/src/modules/endpoints/endpoints.schemas.ts). No React Native imports, so it's tested
 * under Node.
 */
import type {
  AuthType,
  CheckType,
  CreateEndpointInput,
  Endpoint,
  JsonAssertion,
  MatchMode,
  UpdateEndpointInput,
  VersionCheckConfig,
} from '../api/endpoints';

// ── Backend limits ──

export const LIMITS = {
  nameMaxLength: 255,
  groupMaxLength: 100,
  statusCodeMin: 100,
  statusCodeMax: 599,
  intervalMinSeconds: 30,
  intervalMaxSeconds: 86_400,
  everyNChecksMin: 1,
  everyNChecksMax: 1000,
} as const;

export const DEFAULTS = {
  expectedStatusCode: 200,
  checkInterval: 300,
  everyNChecks: 5,
} as const;

// ── Form state ──

/** One editable assertion row. `key` is a client-only id for list rendering. */
export interface AssertionDraft {
  key: string;
  path: string;
  expectedValue: string;
  matchMode: MatchMode;
}

export interface VersionDraft {
  isEnabled: boolean;
  url: string;
  everyNChecks: string;
  versionFieldPath: string;
  assertions: AssertionDraft[];
  authType: AuthType;
  authUsername: string;
  authHeaderName: string;
  /** Never prefilled; blank on edit keeps the stored secret. */
  secret: string;
}

export interface EndpointFormState {
  name: string;
  url: string;
  checkType: CheckType;
  /** Text, so a half-typed value can be validated with a clear message. */
  expectedStatusCode: string;
  checkInterval: string;
  groupName: string;
  healthStandard: boolean;
  authType: AuthType;
  authUsername: string;
  authHeaderName: string;
  /** Never prefilled; blank on edit keeps the stored secret. */
  authSecret: string;
  jsonAssertions: AssertionDraft[];
  version: VersionDraft;
}

let assertionKeyCounter = 0;
export function newAssertionDraft(partial: Partial<Omit<AssertionDraft, 'key'>> = {}): AssertionDraft {
  assertionKeyCounter += 1;
  return { key: `a${assertionKeyCounter}`, path: '', expectedValue: '', matchMode: 'exact', ...partial };
}

function draftsFrom(assertions: JsonAssertion[] | undefined | null): AssertionDraft[] {
  return (assertions ?? []).map((assertion) =>
    newAssertionDraft({
      path: assertion.path,
      expectedValue: assertion.expectedValue,
      matchMode: assertion.matchMode ?? 'exact',
    }),
  );
}

export function emptyVersionDraft(): VersionDraft {
  return {
    isEnabled: false,
    url: '',
    everyNChecks: String(DEFAULTS.everyNChecks),
    versionFieldPath: '',
    assertions: [],
    authType: 'none',
    authUsername: '',
    authHeaderName: '',
    secret: '',
  };
}

export function versionDraftFrom(config: VersionCheckConfig | null | undefined): VersionDraft {
  if (!config) return emptyVersionDraft();
  return {
    isEnabled: config.isEnabled,
    url: config.url,
    everyNChecks: String(config.everyNChecks),
    versionFieldPath: config.versionFieldPath,
    assertions: draftsFrom(config.assertions),
    authType: config.authType,
    authUsername: config.authUsername ?? '',
    authHeaderName: config.authHeaderName ?? '',
    secret: '',
  };
}

export function emptyFormState(): EndpointFormState {
  return {
    name: '',
    url: '',
    checkType: 'http',
    expectedStatusCode: String(DEFAULTS.expectedStatusCode),
    checkInterval: String(DEFAULTS.checkInterval),
    groupName: '',
    healthStandard: false,
    authType: 'none',
    authUsername: '',
    authHeaderName: '',
    authSecret: '',
    jsonAssertions: [],
    version: emptyVersionDraft(),
  };
}

/** Prefills the form from a saved endpoint. Secrets are never prefilled (the API never returns them). */
export function formStateFromEndpoint(endpoint: Endpoint): EndpointFormState {
  return {
    name: endpoint.name,
    url: endpoint.url,
    checkType: endpoint.checkType,
    expectedStatusCode: String(endpoint.expectedStatusCode),
    checkInterval: String(endpoint.checkInterval),
    groupName: endpoint.groupName ?? '',
    healthStandard: endpoint.healthStandard ?? false,
    authType: endpoint.authType,
    authUsername: endpoint.authUsername ?? '',
    authHeaderName: endpoint.authHeaderName ?? '',
    authSecret: '',
    jsonAssertions: draftsFrom(endpoint.jsonAssertions),
    version: versionDraftFrom(endpoint.versionCheck),
  };
}

/** Advanced starts expanded when editing an endpoint whose version check is on, like macOS. */
export function shouldExpandAdvanced(endpoint: Endpoint | null): boolean {
  return endpoint?.versionCheck?.isEnabled === true;
}

// ── Field visibility ──

/** The expected status code applies to HTTP checks that don't use the Health Standard. */
export function showsExpectedStatusCode(state: Pick<EndpointFormState, 'checkType' | 'healthStandard'>): boolean {
  return state.checkType === 'http' && !state.healthStandard;
}

/** Auth, JSON assertions and the Health Standard are HTTP-only. */
export function showsHttpOnlyFields(state: Pick<EndpointFormState, 'checkType'>): boolean {
  return state.checkType === 'http';
}

export function secretLabel(authType: AuthType): string {
  switch (authType) {
    case 'bearer_token':
      return 'Token';
    case 'basic_auth':
      return 'Password';
    case 'custom_header':
      return 'Header value';
    default:
      return 'Secret';
  }
}

/**
 * Whether a blank secret field keeps a stored secret: editing, and the saved auth type is the same
 * (non-none) one. Otherwise a new secret is required.
 */
export function canKeepSecret(originalAuthType: AuthType | null | undefined, authType: AuthType): boolean {
  return authType !== 'none' && originalAuthType === authType;
}

// ── Parsing helpers ──

/** Parses a whole number (digits only, surrounding whitespace allowed). */
export function parseWholeNumber(value: string): number | null {
  const trimmed = value.trim();
  if (!/^\d+$/.test(trimmed)) return null;
  const parsed = Number(trimmed);
  return Number.isSafeInteger(parsed) ? parsed : null;
}

/** http(s)://host[...]; no whitespace. Regex-based so it behaves the same on every platform. */
export function isValidHttpUrl(value: string): boolean {
  return /^https?:\/\/[^\s/?#@]+(?:@[^\s/?#@]+)?(?:[/?#]\S*)?$/i.test(value.trim()) && hostOf(value.trim()) !== '';
}

function hostOf(url: string): string {
  const match = /^[a-z]+:\/\/(?:[^\s/?#@]*@)?(\[[^\]]*\]|[^\s/?#:]*)/i.exec(url);
  return match?.[1] ?? '';
}

/** tcp://host:port with a port of 1–65535 (IPv6 hosts in brackets). */
export function isValidTcpUrl(value: string): boolean {
  const match = /^tcp:\/\/(\[[0-9a-f:.]+\]|[^\s/?#:@[\]]+):(\d{1,5})\/?$/i.exec(value.trim());
  if (!match) return false;
  const port = Number(match[2]);
  return port >= 1 && port <= 65_535;
}

export type AssertionCleanResult =
  | { ok: true; assertions: JsonAssertion[] }
  | { ok: false; rowIndex: number };

/**
 * Trims every row and drops fully blank ones. A half-filled row (path without value or vice
 * versa) is rejected with its index, like macOS `JSONAssertion.cleaned`.
 */
export function cleanAssertions(rows: AssertionDraft[]): AssertionCleanResult {
  const assertions: JsonAssertion[] = [];
  for (let index = 0; index < rows.length; index += 1) {
    const path = rows[index].path.trim();
    const expectedValue = rows[index].expectedValue.trim();
    if (!path && !expectedValue) continue;
    if (!path || !expectedValue) return { ok: false, rowIndex: index };
    assertions.push({ path, expectedValue, matchMode: rows[index].matchMode });
  }
  return { ok: true, assertions };
}

/** Like `cleanAssertions` but drops half-filled rows instead of rejecting (paused version checks). */
export function cleanAssertionsLenient(rows: AssertionDraft[]): JsonAssertion[] {
  return rows.flatMap((row) => {
    const result = cleanAssertions([row]);
    return result.ok ? result.assertions : [];
  });
}

function trimmedOrNull(value: string): string | null {
  const trimmed = value.trim();
  return trimmed ? trimmed : null;
}

// ── Validation ──

export type FormField =
  | 'name'
  | 'url'
  | 'expectedStatusCode'
  | 'checkInterval'
  | 'groupName'
  | 'authUsername'
  | 'authHeaderName'
  | 'authSecret'
  | 'jsonAssertions'
  | 'versionUrl'
  | 'versionEveryNChecks'
  | 'versionFieldPath'
  | 'versionAssertions'
  | 'versionAuthHeaderName'
  | 'versionSecret';

export type FormErrors = Partial<Record<FormField, string>>;

/** Fields inside the collapsible "Advanced" section, so the UI can expand it on error. */
export const ADVANCED_FIELDS: readonly FormField[] = [
  'versionUrl',
  'versionEveryNChecks',
  'versionFieldPath',
  'versionAssertions',
  'versionAuthHeaderName',
  'versionSecret',
];

export type FormResult =
  | { ok: true; mode: 'create'; payload: CreateEndpointInput }
  | { ok: true; mode: 'update'; payload: UpdateEndpointInput }
  | { ok: false; errors: FormErrors };

interface VersionOutcome {
  /** `undefined` = nothing to send on create; `null` = no / remove version check. */
  config: VersionCheckConfig | null;
  secret: string | undefined;
}

/**
 * Version check rules (macOS `VersionCheckDraft.validate`):
 * - Enabled: URL, N, field path, assertions and header name must be valid; a secret is required
 *   unless the saved version check already has a secret for the same auth type.
 * - Disabled: never blocks saving. Kept as a paused config so re-enabling needs no retyping, as
 *   long as the backend can store it (valid http(s) URL and a field path); otherwise dropped.
 *   Half-filled assertion rows are dropped, N is clamped.
 */
function validateVersion(
  draft: VersionDraft,
  original: VersionCheckConfig | null | undefined,
  errors: FormErrors,
): VersionOutcome {
  const secret = draft.secret.trim();
  const path = draft.versionFieldPath.trim();
  const url = draft.url.trim();
  const authFields = {
    authType: draft.authType,
    authUsername: draft.authType === 'basic_auth' ? trimmedOrNull(draft.authUsername) : null,
    authHeaderName: draft.authType === 'custom_header' ? trimmedOrNull(draft.authHeaderName) : null,
  };

  if (!draft.isEnabled) {
    if (!isValidHttpUrl(url) || !path) {
      return { config: null, secret: undefined };
    }
    const everyN = parseWholeNumber(draft.everyNChecks);
    return {
      config: {
        isEnabled: false,
        url,
        everyNChecks:
          everyN === null
            ? DEFAULTS.everyNChecks
            : Math.min(Math.max(everyN, LIMITS.everyNChecksMin), LIMITS.everyNChecksMax),
        versionFieldPath: path,
        assertions: cleanAssertionsLenient(draft.assertions),
        ...authFields,
      },
      secret: draft.authType !== 'none' && secret ? secret : undefined,
    };
  }

  const before = Object.keys(errors).length;
  if (!isValidHttpUrl(url)) {
    errors.versionUrl = 'Enter a valid http(s) URL for the version check';
  }
  const everyN = parseWholeNumber(draft.everyNChecks);
  if (everyN === null || everyN < LIMITS.everyNChecksMin || everyN > LIMITS.everyNChecksMax) {
    errors.versionEveryNChecks = `Enter a whole number between ${LIMITS.everyNChecksMin} and ${LIMITS.everyNChecksMax}`;
  }
  if (!path) {
    errors.versionFieldPath = 'Enter the JSON field that holds the version, e.g. data.version';
  }
  const assertions = cleanAssertions(draft.assertions);
  if (!assertions.ok) {
    errors.versionAssertions = `Version assertion ${assertions.rowIndex + 1} needs both a field path and an expected value`;
  }
  if (draft.authType === 'custom_header' && !authFields.authHeaderName) {
    errors.versionAuthHeaderName = "Enter a header name for the version check's custom header auth";
  }
  if (draft.authType !== 'none' && !secret && !canKeepSecret(original?.authType, draft.authType)) {
    errors.versionSecret = `Enter a ${secretLabel(draft.authType).toLowerCase()} for the version check`;
  }
  if (Object.keys(errors).length > before || !assertions.ok || everyN === null) {
    return { config: null, secret: undefined };
  }

  return {
    config: {
      isEnabled: true,
      url,
      everyNChecks: everyN,
      versionFieldPath: path,
      assertions: assertions.assertions,
      ...authFields,
    },
    secret: draft.authType !== 'none' && secret ? secret : undefined,
  };
}

/**
 * Validates the whole form and builds the request body.
 * - `original === null`: create, with every field.
 * - Otherwise: a partial update with only the fields that changed, plus any new secrets.
 *
 * TCP checks drop the HTTP-only settings (Health Standard, assertions, auth), like macOS. The
 * expected status code is hidden (and its value ignored) for the Health Standard, so a leftover
 * invalid value there never blocks saving; the saved value is kept instead.
 */
export function validateEndpointForm(state: EndpointFormState, original: Endpoint | null): FormResult {
  const errors: FormErrors = {};
  const isHttp = state.checkType === 'http';

  const name = state.name.trim();
  if (!name) {
    errors.name = 'Enter a name';
  } else if (name.length > LIMITS.nameMaxLength) {
    errors.name = `Name must be at most ${LIMITS.nameMaxLength} characters`;
  }

  const url = state.url.trim();
  if (isHttp && !isValidHttpUrl(url)) {
    errors.url = 'Enter a valid http(s) URL, e.g. https://api.example.com/health';
  } else if (!isHttp && !isValidTcpUrl(url)) {
    errors.url = 'Enter a host and port as tcp://host:port, e.g. tcp://db.example.com:5432';
  }

  const fallbackStatusCode = original?.expectedStatusCode ?? DEFAULTS.expectedStatusCode;
  let expectedStatusCode = fallbackStatusCode;
  const parsedStatus = parseWholeNumber(state.expectedStatusCode);
  const statusInRange =
    parsedStatus !== null && parsedStatus >= LIMITS.statusCodeMin && parsedStatus <= LIMITS.statusCodeMax;
  if (showsExpectedStatusCode(state)) {
    if (statusInRange) {
      expectedStatusCode = parsedStatus;
    } else {
      errors.expectedStatusCode = `Enter an HTTP status code between ${LIMITS.statusCodeMin} and ${LIMITS.statusCodeMax}`;
    }
  } else if (isHttp && statusInRange) {
    // Hidden by the Health Standard: keep a valid typed value, ignore an invalid one.
    expectedStatusCode = parsedStatus;
  }

  const interval = parseWholeNumber(state.checkInterval);
  if (interval === null || interval < LIMITS.intervalMinSeconds || interval > LIMITS.intervalMaxSeconds) {
    errors.checkInterval = `Enter a whole number of seconds between ${LIMITS.intervalMinSeconds} and ${LIMITS.intervalMaxSeconds}`;
  }

  const groupName = trimmedOrNull(state.groupName);
  if (groupName && groupName.length > LIMITS.groupMaxLength) {
    errors.groupName = `Group must be at most ${LIMITS.groupMaxLength} characters`;
  }

  // HTTP-only settings; TCP clears them.
  let healthStandard = false;
  let jsonAssertions: JsonAssertion[] = [];
  let authType: AuthType = 'none';
  let authUsername: string | null = null;
  let authHeaderName: string | null = null;
  let authSecret: string | undefined;

  if (isHttp) {
    healthStandard = state.healthStandard;
    authType = state.authType;
    authUsername = authType === 'basic_auth' ? trimmedOrNull(state.authUsername) : null;
    authHeaderName = authType === 'custom_header' ? trimmedOrNull(state.authHeaderName) : null;

    if (authType === 'custom_header' && !authHeaderName) {
      errors.authHeaderName = 'Enter a header name for custom header auth';
    }
    const secret = state.authSecret.trim();
    if (authType !== 'none') {
      if (secret) {
        authSecret = secret;
      } else if (!canKeepSecret(original?.authType, authType)) {
        errors.authSecret = `Enter a ${secretLabel(authType).toLowerCase()}`;
      }
    }

    const cleaned = cleanAssertions(state.jsonAssertions);
    if (cleaned.ok) {
      jsonAssertions = cleaned.assertions;
    } else {
      errors.jsonAssertions = `Assertion ${cleaned.rowIndex + 1} needs both a field path and an expected value`;
    }
  }

  const version = validateVersion(state.version, original?.versionCheck, errors);

  if (Object.keys(errors).length > 0) {
    return { ok: false, errors };
  }

  const fields = {
    name,
    url,
    checkType: state.checkType,
    expectedStatusCode,
    checkInterval: interval as number,
    groupName,
    jsonAssertions,
    authType,
    authUsername,
    authHeaderName,
    healthStandard,
  };

  if (!original) {
    const payload: CreateEndpointInput = { ...fields };
    if (authSecret) payload.authSecret = authSecret;
    if (version.config) {
      payload.versionCheck = version.config;
      if (version.secret) payload.versionAuthSecret = version.secret;
    }
    return { ok: true, mode: 'create', payload };
  }

  const payload: UpdateEndpointInput = {};
  const originalFields = {
    name: original.name,
    url: original.url,
    checkType: original.checkType,
    expectedStatusCode: original.expectedStatusCode,
    checkInterval: original.checkInterval,
    groupName: original.groupName ?? null,
    jsonAssertions: normalizeAssertions(original.jsonAssertions),
    authType: original.authType,
    authUsername: original.authUsername ?? null,
    authHeaderName: original.authHeaderName ?? null,
    healthStandard: original.healthStandard ?? false,
  };
  for (const key of Object.keys(fields) as Array<keyof typeof fields>) {
    if (!isEqual(fields[key], originalFields[key])) {
      (payload as Record<string, unknown>)[key] = fields[key];
    }
  }
  if (authSecret) payload.authSecret = authSecret;

  const originalVersion = original.versionCheck ? normalizeVersionConfig(original.versionCheck) : null;
  if (!isEqual(version.config, originalVersion)) {
    payload.versionCheck = version.config;
  }
  if (version.config && version.secret) payload.versionAuthSecret = version.secret;

  return { ok: true, mode: 'update', payload };
}

/** True when an update payload would change nothing. */
export function isEmptyUpdate(payload: UpdateEndpointInput): boolean {
  return Object.keys(payload).length === 0;
}

function normalizeAssertions(assertions: JsonAssertion[] | null | undefined): JsonAssertion[] {
  return (assertions ?? []).map((assertion) => ({
    path: assertion.path,
    expectedValue: assertion.expectedValue,
    matchMode: assertion.matchMode ?? 'exact',
  }));
}

function normalizeVersionConfig(config: VersionCheckConfig): VersionCheckConfig {
  return {
    isEnabled: config.isEnabled,
    url: config.url,
    everyNChecks: config.everyNChecks,
    versionFieldPath: config.versionFieldPath,
    assertions: normalizeAssertions(config.assertions),
    authType: config.authType,
    authUsername: config.authUsername ?? null,
    authHeaderName: config.authHeaderName ?? null,
  };
}

/** Structural equality for JSON-like values (key order independent). */
function isEqual(a: unknown, b: unknown): boolean {
  if (a === b) return true;
  if (a === null || b === null || typeof a !== 'object' || typeof b !== 'object') return false;
  if (Array.isArray(a) !== Array.isArray(b)) return false;
  if (Array.isArray(a) && Array.isArray(b)) {
    return a.length === b.length && a.every((item, index) => isEqual(item, b[index]));
  }
  const aKeys = Object.keys(a as object);
  const bKeys = Object.keys(b as object);
  return (
    aKeys.length === bKeys.length &&
    aKeys.every((key) => isEqual((a as Record<string, unknown>)[key], (b as Record<string, unknown>)[key]))
  );
}

// ── Backend errors ──

const FIELD_LABELS: Record<string, string> = {
  name: 'Name',
  url: 'URL',
  checkType: 'Check type',
  expectedStatusCode: 'Expected status code',
  checkInterval: 'Check interval',
  groupName: 'Group',
  jsonAssertions: 'JSON assertions',
  authType: 'Auth type',
  authUsername: 'Username',
  authHeaderName: 'Header name',
  authSecret: 'Secret',
  versionCheck: 'Version check',
  versionAuthSecret: 'Version check secret',
  healthStandard: 'Zext Health Standard',
};

/**
 * Turns a backend error body into readable lines. Handles `{ error: string }` and zod's
 * `flatten()` shape (`{ error: { formErrors, fieldErrors } }`), naming each field.
 */
export function describeApiError(body: unknown, fallback: string): string[] {
  if (!body || typeof body !== 'object' || !('error' in body)) return [fallback];
  const error = (body as { error: unknown }).error;
  if (typeof error === 'string') return [error || fallback];
  if (!error || typeof error !== 'object') return [fallback];

  const flat = error as { formErrors?: unknown; fieldErrors?: unknown };
  const lines: string[] = [];
  if (Array.isArray(flat.formErrors)) {
    for (const message of flat.formErrors) {
      if (typeof message === 'string' && message) lines.push(message);
    }
  }
  if (flat.fieldErrors && typeof flat.fieldErrors === 'object') {
    for (const [field, messages] of Object.entries(flat.fieldErrors as Record<string, unknown>)) {
      if (!Array.isArray(messages)) continue;
      const label = FIELD_LABELS[field] ?? field;
      for (const message of messages) {
        if (typeof message === 'string' && message) lines.push(`${label}: ${message}`);
      }
    }
  }
  return lines.length > 0 ? lines : [fallback];
}
