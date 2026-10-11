/// <reference types="node" />
import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import type { Endpoint, VersionCheckConfig } from '../api/endpoints';
import {
  ADVANCED_FIELDS,
  canKeepSecret,
  cleanAssertions,
  cleanAssertionsLenient,
  describeApiError,
  emptyFormState,
  formStateFromEndpoint,
  isEmptyUpdate,
  isValidHttpUrl,
  isValidTcpUrl,
  newAssertionDraft,
  parseWholeNumber,
  secretLabel,
  shouldExpandAdvanced,
  showsExpectedStatusCode,
  showsHttpOnlyFields,
  validateEndpointForm,
  type EndpointFormState,
  type FormResult,
} from './endpointForm';

// ── Fixtures ──

function form(overrides: Partial<EndpointFormState> = {}): EndpointFormState {
  return { ...emptyFormState(), name: 'API', url: 'https://api.example.com/health', ...overrides };
}

function versionConfig(overrides: Partial<VersionCheckConfig> = {}): VersionCheckConfig {
  return {
    isEnabled: true,
    url: 'https://api.example.com/version',
    everyNChecks: 5,
    versionFieldPath: 'data.version',
    assertions: [],
    authType: 'none',
    authUsername: null,
    authHeaderName: null,
    ...overrides,
  };
}

function endpoint(overrides: Partial<Endpoint> = {}): Endpoint {
  return {
    id: '00000000-0000-0000-0000-000000000001',
    userId: 'u1',
    name: 'API',
    url: 'https://api.example.com/health',
    checkType: 'http',
    expectedStatusCode: 200,
    checkInterval: 300,
    groupName: null,
    jsonAssertions: [],
    authType: 'none',
    authUsername: null,
    authHeaderName: null,
    isPaused: false,
    versionCheck: null,
    healthStandard: false,
    createdAt: '2026-10-01T00:00:00.000Z',
    updatedAt: '2026-10-01T00:00:00.000Z',
    ...overrides,
  };
}

function expectOk(result: FormResult) {
  if (!result.ok) assert.fail(`expected ok, got errors ${JSON.stringify(result.errors)}`);
  return result;
}

function expectErrors(result: FormResult) {
  if (result.ok) assert.fail(`expected errors, got payload ${JSON.stringify(result.payload)}`);
  return result.errors;
}

/** Edit-mode round trip: the form prefilled from `original`, then `edit` applied. */
function update(original: Endpoint, edit: (state: EndpointFormState) => EndpointFormState = (s) => s) {
  return validateEndpointForm(edit(formStateFromEndpoint(original)), original);
}

// ── Parsing helpers ──

describe('parseWholeNumber', () => {
  it('parses digits with surrounding whitespace', () => {
    assert.equal(parseWholeNumber('300'), 300);
    assert.equal(parseWholeNumber(' 42 '), 42);
    assert.equal(parseWholeNumber('0'), 0);
  });

  it('rejects anything else', () => {
    for (const value of ['', ' ', '1.5', '-1', '1e3', '12a', '+5', '0x10', '99999999999999999999']) {
      assert.equal(parseWholeNumber(value), null, value);
    }
  });
});

describe('isValidHttpUrl', () => {
  it('accepts http(s) URLs', () => {
    for (const url of [
      'https://api.example.com/health',
      'http://localhost:3001',
      'https://example.com?x=1',
      'HTTPS://EXAMPLE.COM/',
      ' https://example.com/health ',
      'https://user:pass@example.com/x',
      'http://[::1]:8080/health',
    ]) {
      assert.equal(isValidHttpUrl(url), true, url);
    }
  });

  it('rejects other schemes, missing hosts and whitespace', () => {
    for (const url of ['', 'example.com', 'ftp://example.com', 'tcp://db:5432', 'https://', 'https:///x', 'https://exa mple.com', 'https://:80/']) {
      assert.equal(isValidHttpUrl(url), false, url);
    }
  });
});

describe('isValidTcpUrl', () => {
  it('accepts tcp://host:port', () => {
    for (const url of ['tcp://db.example.com:5432', 'tcp://10.0.0.1:6379', 'TCP://db:1', 'tcp://db:65535/', 'tcp://[::1]:5432', ' tcp://db:22 ']) {
      assert.equal(isValidTcpUrl(url), true, url);
    }
  });

  it('rejects a missing or invalid port, other schemes and paths', () => {
    for (const url of ['tcp://db', 'tcp://db:', 'tcp://db:0', 'tcp://db:65536', 'tcp://:5432', 'db:5432', 'https://db:5432', 'tcp://db:5432/path', 'tcp://db:abc']) {
      assert.equal(isValidTcpUrl(url), false, url);
    }
  });
});

describe('cleanAssertions', () => {
  it('trims rows and drops fully blank ones', () => {
    const result = cleanAssertions([
      newAssertionDraft({ path: ' data.status ', expectedValue: ' ok ', matchMode: 'contains' }),
      newAssertionDraft({ path: '  ', expectedValue: '' }),
      newAssertionDraft({ path: 'version', expectedValue: '^1\\.', matchMode: 'regex' }),
    ]);
    assert.deepEqual(result, {
      ok: true,
      assertions: [
        { path: 'data.status', expectedValue: 'ok', matchMode: 'contains' },
        { path: 'version', expectedValue: '^1\\.', matchMode: 'regex' },
      ],
    });
  });

  it('rejects half-filled rows with the row index', () => {
    assert.deepEqual(
      cleanAssertions([newAssertionDraft({ path: 'a', expectedValue: '1' }), newAssertionDraft({ path: 'b' })]),
      { ok: false, rowIndex: 1 },
    );
    assert.deepEqual(cleanAssertions([newAssertionDraft({ expectedValue: 'x' })]), { ok: false, rowIndex: 0 });
  });

  it('is ok for an empty list', () => {
    assert.deepEqual(cleanAssertions([]), { ok: true, assertions: [] });
  });

  it('lenient variant drops half-filled rows instead', () => {
    assert.deepEqual(
      cleanAssertionsLenient([
        newAssertionDraft({ path: 'b' }),
        newAssertionDraft({ path: ' a ', expectedValue: ' 1 ' }),
        newAssertionDraft({ expectedValue: 'x' }),
      ]),
      [{ path: 'a', expectedValue: '1', matchMode: 'exact' }],
    );
  });

  it('gives each draft row a unique key', () => {
    assert.notEqual(newAssertionDraft().key, newAssertionDraft().key);
  });
});

// ── State helpers ──

describe('form state', () => {
  it('starts with backend defaults', () => {
    const state = emptyFormState();
    assert.equal(state.checkType, 'http');
    assert.equal(state.expectedStatusCode, '200');
    assert.equal(state.checkInterval, '300');
    assert.equal(state.version.everyNChecks, '5');
    assert.equal(state.version.isEnabled, false);
    assert.equal(state.healthStandard, false);
    assert.equal(state.authType, 'none');
  });

  it('prefills from an endpoint, never the secrets', () => {
    const state = formStateFromEndpoint(
      endpoint({
        groupName: 'Prod',
        authType: 'basic_auth',
        authUsername: 'admin',
        healthStandard: true,
        jsonAssertions: [{ path: 'a', expectedValue: '1', matchMode: 'regex' }],
        versionCheck: versionConfig({ authType: 'bearer_token', everyNChecks: 9 }),
      }),
    );
    assert.equal(state.groupName, 'Prod');
    assert.equal(state.authUsername, 'admin');
    assert.equal(state.authSecret, '');
    assert.equal(state.healthStandard, true);
    assert.equal(state.jsonAssertions[0].matchMode, 'regex');
    assert.equal(state.version.isEnabled, true);
    assert.equal(state.version.everyNChecks, '9');
    assert.equal(state.version.authType, 'bearer_token');
    assert.equal(state.version.secret, '');
  });

  it('treats a missing healthStandard / versionCheck (older backend) as off', () => {
    const { healthStandard: _h, versionCheck: _v, ...legacy } = endpoint();
    const state = formStateFromEndpoint(legacy as Endpoint);
    assert.equal(state.healthStandard, false);
    assert.equal(state.version.isEnabled, false);
    assert.equal(state.version.url, '');
  });

  it('expands Advanced only for an enabled version check', () => {
    assert.equal(shouldExpandAdvanced(null), false);
    assert.equal(shouldExpandAdvanced(endpoint()), false);
    assert.equal(shouldExpandAdvanced(endpoint({ versionCheck: versionConfig({ isEnabled: false }) })), false);
    assert.equal(shouldExpandAdvanced(endpoint({ versionCheck: versionConfig() })), true);
  });

  it('shows the expected status code only for HTTP without the Health Standard', () => {
    assert.equal(showsExpectedStatusCode({ checkType: 'http', healthStandard: false }), true);
    assert.equal(showsExpectedStatusCode({ checkType: 'http', healthStandard: true }), false);
    assert.equal(showsExpectedStatusCode({ checkType: 'tcp', healthStandard: false }), false);
    assert.equal(showsHttpOnlyFields({ checkType: 'http' }), true);
    assert.equal(showsHttpOnlyFields({ checkType: 'tcp' }), false);
  });

  it('labels secrets per auth type', () => {
    assert.equal(secretLabel('bearer_token'), 'Token');
    assert.equal(secretLabel('basic_auth'), 'Password');
    assert.equal(secretLabel('custom_header'), 'Header value');
    assert.equal(secretLabel('none'), 'Secret');
  });

  it('keeps a stored secret only for the same non-none auth type', () => {
    assert.equal(canKeepSecret('bearer_token', 'bearer_token'), true);
    assert.equal(canKeepSecret('bearer_token', 'basic_auth'), false);
    assert.equal(canKeepSecret('none', 'bearer_token'), false);
    assert.equal(canKeepSecret(undefined, 'bearer_token'), false);
    assert.equal(canKeepSecret('none', 'none'), false);
  });

  it('lists the Advanced fields', () => {
    assert.ok(ADVANCED_FIELDS.includes('versionUrl'));
    assert.ok(!ADVANCED_FIELDS.includes('url'));
  });
});

// ── Create ──

describe('validateEndpointForm: create', () => {
  it('builds a full, trimmed payload', () => {
    const result = expectOk(
      validateEndpointForm(
        form({
          name: '  API  ',
          url: ' https://api.example.com/health ',
          expectedStatusCode: ' 204 ',
          checkInterval: ' 60 ',
          groupName: '  Production ',
        }),
        null,
      ),
    );
    assert.equal(result.mode, 'create');
    assert.deepEqual(result.payload, {
      name: 'API',
      url: 'https://api.example.com/health',
      checkType: 'http',
      expectedStatusCode: 204,
      checkInterval: 60,
      groupName: 'Production',
      jsonAssertions: [],
      authType: 'none',
      authUsername: null,
      authHeaderName: null,
      healthStandard: false,
    });
  });

  it('sends a blank group as null', () => {
    const result = expectOk(validateEndpointForm(form({ groupName: '   ' }), null));
    assert.equal(result.payload.groupName, null);
  });

  it('requires a name and a valid URL', () => {
    const errors = expectErrors(validateEndpointForm(form({ name: '  ', url: 'example.com' }), null));
    assert.ok(errors.name);
    assert.ok(errors.url);
  });

  it('enforces name and group lengths', () => {
    assert.ok(expectErrors(validateEndpointForm(form({ name: 'x'.repeat(256) }), null)).name);
    expectOk(validateEndpointForm(form({ name: 'x'.repeat(255) }), null));
    assert.ok(expectErrors(validateEndpointForm(form({ groupName: 'g'.repeat(101) }), null)).groupName);
    expectOk(validateEndpointForm(form({ groupName: 'g'.repeat(100) }), null));
  });

  describe('numeric limits', () => {
    it('check interval: whole seconds within 30–86400', () => {
      for (const value of ['29', '86401', '', 'abc', '30.5', '-60']) {
        assert.ok(expectErrors(validateEndpointForm(form({ checkInterval: value }), null)).checkInterval, value);
      }
      assert.equal(expectOk(validateEndpointForm(form({ checkInterval: '30' }), null)).payload.checkInterval, 30);
      assert.equal(expectOk(validateEndpointForm(form({ checkInterval: '86400' }), null)).payload.checkInterval, 86400);
    });

    it('expected status code: 100–599 when shown', () => {
      for (const value of ['99', '600', '', 'ok', '200.0']) {
        assert.ok(expectErrors(validateEndpointForm(form({ expectedStatusCode: value }), null)).expectedStatusCode, value);
      }
      assert.equal(expectOk(validateEndpointForm(form({ expectedStatusCode: '100' }), null)).payload.expectedStatusCode, 100);
      assert.equal(expectOk(validateEndpointForm(form({ expectedStatusCode: '599' }), null)).payload.expectedStatusCode, 599);
    });

    it('version check every N: 1–1000 when enabled', () => {
      const version = (everyNChecks: string) => ({
        ...emptyFormState().version,
        isEnabled: true,
        url: 'https://api.example.com/version',
        versionFieldPath: 'version',
        everyNChecks,
      });
      for (const value of ['0', '1001', '', 'five', '2.5']) {
        assert.ok(
          expectErrors(validateEndpointForm(form({ version: version(value) }), null)).versionEveryNChecks,
          value,
        );
      }
      assert.equal(
        expectOk(validateEndpointForm(form({ version: version('1') }), null)).payload.versionCheck?.everyNChecks,
        1,
      );
      assert.equal(
        expectOk(validateEndpointForm(form({ version: version('1000') }), null)).payload.versionCheck?.everyNChecks,
        1000,
      );
    });
  });

  describe('Health Standard', () => {
    it('sends healthStandard and ignores a hidden, invalid status code', () => {
      const result = expectOk(validateEndpointForm(form({ healthStandard: true, expectedStatusCode: 'junk' }), null));
      assert.equal(result.payload.healthStandard, true);
      assert.equal(result.payload.expectedStatusCode, 200);
    });

    it('keeps a valid hidden status code', () => {
      const result = expectOk(validateEndpointForm(form({ healthStandard: true, expectedStatusCode: '204' }), null));
      assert.equal(result.payload.expectedStatusCode, 204);
    });

    it('still validates JSON assertions on top', () => {
      const errors = expectErrors(
        validateEndpointForm(form({ healthStandard: true, jsonAssertions: [newAssertionDraft({ path: 'a' })] }), null),
      );
      assert.match(errors.jsonAssertions ?? '', /Assertion 1/);
    });
  });

  describe('TCP', () => {
    it('requires tcp://host:port', () => {
      assert.ok(expectErrors(validateEndpointForm(form({ checkType: 'tcp', url: 'https://db:5432' }), null)).url);
      assert.ok(expectErrors(validateEndpointForm(form({ checkType: 'tcp', url: 'tcp://db' }), null)).url);
      expectOk(validateEndpointForm(form({ checkType: 'tcp', url: 'tcp://db.example.com:5432' }), null));
    });

    it('rejects a tcp URL for an http check', () => {
      assert.ok(expectErrors(validateEndpointForm(form({ url: 'tcp://db:5432' }), null)).url);
    });

    it('drops HTTP-only settings and their validation', () => {
      const result = expectOk(
        validateEndpointForm(
          form({
            checkType: 'tcp',
            url: 'tcp://db:5432',
            healthStandard: true,
            expectedStatusCode: 'junk',
            authType: 'custom_header',
            authHeaderName: '',
            authSecret: '',
            jsonAssertions: [newAssertionDraft({ path: 'half' })],
          }),
          null,
        ),
      );
      assert.deepEqual(
        {
          checkType: result.payload.checkType,
          healthStandard: result.payload.healthStandard,
          expectedStatusCode: result.payload.expectedStatusCode,
          authType: result.payload.authType,
          authUsername: result.payload.authUsername,
          authHeaderName: result.payload.authHeaderName,
          jsonAssertions: result.payload.jsonAssertions,
          authSecret: result.payload.authSecret,
        },
        {
          checkType: 'tcp',
          healthStandard: false,
          expectedStatusCode: 200,
          authType: 'none',
          authUsername: null,
          authHeaderName: null,
          jsonAssertions: [],
          authSecret: undefined,
        },
      );
    });
  });

  describe('auth', () => {
    it('requires a secret for new auth', () => {
      for (const authType of ['bearer_token', 'basic_auth', 'custom_header'] as const) {
        const errors = expectErrors(
          validateEndpointForm(form({ authType, authUsername: 'u', authHeaderName: 'X-Key' }), null),
        );
        assert.ok(errors.authSecret, authType);
      }
    });

    it('sends the trimmed secret and only the relevant auth fields', () => {
      const bearer = expectOk(
        validateEndpointForm(
          form({ authType: 'bearer_token', authSecret: ' tok ', authUsername: 'ignored', authHeaderName: 'ignored' }),
          null,
        ),
      );
      assert.equal(bearer.payload.authSecret, 'tok');
      assert.equal(bearer.payload.authUsername, null);
      assert.equal(bearer.payload.authHeaderName, null);

      const basic = expectOk(
        validateEndpointForm(form({ authType: 'basic_auth', authUsername: ' admin ', authSecret: 'pw' }), null),
      );
      assert.equal(basic.payload.authUsername, 'admin');
      assert.equal(basic.payload.authHeaderName, null);

      const header = expectOk(
        validateEndpointForm(form({ authType: 'custom_header', authHeaderName: ' X-Key ', authSecret: 'v' }), null),
      );
      assert.equal(header.payload.authHeaderName, 'X-Key');
      assert.equal(header.payload.authUsername, null);
    });

    it('requires a header name for custom header auth', () => {
      assert.ok(
        expectErrors(validateEndpointForm(form({ authType: 'custom_header', authHeaderName: ' ', authSecret: 'v' }), null))
          .authHeaderName,
      );
    });

    it('never sends a secret for auth none', () => {
      const result = expectOk(validateEndpointForm(form({ authType: 'none', authSecret: 'leftover' }), null));
      assert.equal(result.payload.authSecret, undefined);
    });

    it('treats a whitespace-only secret as blank', () => {
      assert.ok(expectErrors(validateEndpointForm(form({ authType: 'bearer_token', authSecret: '   ' }), null)).authSecret);
    });
  });

  describe('JSON assertions', () => {
    it('cleans rows and drops blank ones', () => {
      const result = expectOk(
        validateEndpointForm(
          form({
            jsonAssertions: [
              newAssertionDraft({ path: ' status ', expectedValue: ' ok ' }),
              newAssertionDraft(),
              newAssertionDraft({ path: 'version', expectedValue: '1', matchMode: 'contains' }),
            ],
          }),
          null,
        ),
      );
      assert.deepEqual(result.payload.jsonAssertions, [
        { path: 'status', expectedValue: 'ok', matchMode: 'exact' },
        { path: 'version', expectedValue: '1', matchMode: 'contains' },
      ]);
    });

    it('rejects half-filled rows, naming the row', () => {
      const errors = expectErrors(
        validateEndpointForm(
          form({ jsonAssertions: [newAssertionDraft({ path: 'a', expectedValue: '1' }), newAssertionDraft({ expectedValue: 'x' })] }),
          null,
        ),
      );
      assert.match(errors.jsonAssertions ?? '', /Assertion 2/);
    });
  });

  describe('version check', () => {
    const enabledVersion = (overrides: Partial<EndpointFormState['version']> = {}) => ({
      ...emptyFormState().version,
      isEnabled: true,
      url: ' https://api.example.com/version ',
      versionFieldPath: ' data.version ',
      ...overrides,
    });

    it('omits versionCheck when disabled and empty', () => {
      const result = expectOk(validateEndpointForm(form(), null));
      assert.equal('versionCheck' in result.payload, false);
      assert.equal('versionAuthSecret' in result.payload, false);
    });

    it('builds an enabled, trimmed config', () => {
      const result = expectOk(
        validateEndpointForm(
          form({
            version: enabledVersion({
              everyNChecks: ' 10 ',
              assertions: [newAssertionDraft({ path: ' env ', expectedValue: ' prod ' }), newAssertionDraft()],
            }),
          }),
          null,
        ),
      );
      assert.deepEqual(result.payload.versionCheck, {
        isEnabled: true,
        url: 'https://api.example.com/version',
        everyNChecks: 10,
        versionFieldPath: 'data.version',
        assertions: [{ path: 'env', expectedValue: 'prod', matchMode: 'exact' }],
        authType: 'none',
        authUsername: null,
        authHeaderName: null,
      });
    });

    it('validates every enabled field', () => {
      const errors = expectErrors(
        validateEndpointForm(
          form({
            version: enabledVersion({
              url: 'ftp://x',
              everyNChecks: '0',
              versionFieldPath: ' ',
              assertions: [newAssertionDraft({ path: 'a' })],
              authType: 'custom_header',
              authHeaderName: '',
            }),
          }),
          null,
        ),
      );
      assert.ok(errors.versionUrl);
      assert.ok(errors.versionEveryNChecks);
      assert.ok(errors.versionFieldPath);
      assert.match(errors.versionAssertions ?? '', /Version assertion 1/);
      assert.ok(errors.versionAuthHeaderName);
      assert.ok(errors.versionSecret);
      for (const key of Object.keys(errors)) {
        assert.ok(ADVANCED_FIELDS.includes(key as never), key);
      }
    });

    it('requires and sends a separate version secret', () => {
      assert.ok(
        expectErrors(validateEndpointForm(form({ version: enabledVersion({ authType: 'bearer_token' }) }), null)).versionSecret,
      );
      const result = expectOk(
        validateEndpointForm(
          form({
            authType: 'bearer_token',
            authSecret: 'main',
            version: enabledVersion({ authType: 'basic_auth', authUsername: ' ver ', secret: ' vsecret ' }),
          }),
          null,
        ),
      );
      assert.equal(result.payload.authSecret, 'main');
      assert.equal(result.payload.versionAuthSecret, 'vsecret');
      assert.equal(result.payload.versionCheck?.authUsername, 'ver');
      assert.equal(result.payload.versionCheck?.authHeaderName, null);
    });

    it('keeps a disabled config (paused) without blocking on its fields', () => {
      const result = expectOk(
        validateEndpointForm(
          form({
            version: enabledVersion({
              isEnabled: false,
              everyNChecks: '5000',
              assertions: [newAssertionDraft({ path: 'half' }), newAssertionDraft({ path: 'a', expectedValue: '1' })],
              authType: 'bearer_token',
            }),
          }),
          null,
        ),
      );
      assert.deepEqual(result.payload.versionCheck, {
        isEnabled: false,
        url: 'https://api.example.com/version',
        everyNChecks: 1000,
        versionFieldPath: 'data.version',
        assertions: [{ path: 'a', expectedValue: '1', matchMode: 'exact' }],
        authType: 'bearer_token',
        authUsername: null,
        authHeaderName: null,
      });
      assert.equal(result.payload.versionAuthSecret, undefined);
    });

    it('a disabled config clamps N up and defaults junk', () => {
      const clampUp = expectOk(validateEndpointForm(form({ version: enabledVersion({ isEnabled: false, everyNChecks: '0' }) }), null));
      assert.equal(clampUp.payload.versionCheck?.everyNChecks, 1);
      const junk = expectOk(validateEndpointForm(form({ version: enabledVersion({ isEnabled: false, everyNChecks: 'x' }) }), null));
      assert.equal(junk.payload.versionCheck?.everyNChecks, 5);
    });

    it('a disabled config sends a typed secret along', () => {
      const result = expectOk(
        validateEndpointForm(
          form({ version: enabledVersion({ isEnabled: false, authType: 'bearer_token', secret: 's' }) }),
          null,
        ),
      );
      assert.equal(result.payload.versionAuthSecret, 's');
    });

    it('drops a disabled config the backend could not store', () => {
      for (const version of [
        enabledVersion({ isEnabled: false, url: 'not a url' }),
        enabledVersion({ isEnabled: false, versionFieldPath: '' }),
      ]) {
        const result = expectOk(validateEndpointForm(form({ version }), null));
        assert.equal('versionCheck' in result.payload, false);
      }
    });

    it('is allowed on TCP endpoints', () => {
      const result = expectOk(
        validateEndpointForm(form({ checkType: 'tcp', url: 'tcp://db:5432', version: enabledVersion() }), null),
      );
      assert.equal(result.payload.versionCheck?.isEnabled, true);
    });
  });
});

// ── Update ──

describe('validateEndpointForm: update', () => {
  it('sends nothing when nothing changed', () => {
    const original = endpoint({
      groupName: 'Prod',
      jsonAssertions: [{ path: 'a', expectedValue: '1', matchMode: 'exact' }],
      authType: 'bearer_token',
      healthStandard: true,
      versionCheck: versionConfig({ authType: 'custom_header', authHeaderName: 'X-Key' }),
    });
    const result = expectOk(update(original));
    assert.equal(result.mode, 'update');
    assert.deepEqual(result.payload, {});
    assert.equal(isEmptyUpdate(result.payload), true);
  });

  it('sends only changed fields', () => {
    const result = expectOk(
      update(endpoint(), (s) => ({ ...s, name: 'Renamed', checkInterval: '60', groupName: 'Staging' })),
    );
    assert.deepEqual(result.payload, { name: 'Renamed', checkInterval: 60, groupName: 'Staging' });
    assert.equal(isEmptyUpdate(result.payload), false);
  });

  it('clears a group', () => {
    assert.deepEqual(expectOk(update(endpoint({ groupName: 'Prod' }), (s) => ({ ...s, groupName: ' ' }))).payload, {
      groupName: null,
    });
  });

  it('detects assertion changes, including match mode', () => {
    const original = endpoint({ jsonAssertions: [{ path: 'a', expectedValue: '1', matchMode: 'exact' }] });
    const result = expectOk(
      update(original, (s) => ({ ...s, jsonAssertions: s.jsonAssertions.map((row) => ({ ...row, matchMode: 'regex' })) })),
    );
    assert.deepEqual(result.payload, { jsonAssertions: [{ path: 'a', expectedValue: '1', matchMode: 'regex' }] });
    const removed = expectOk(update(original, (s) => ({ ...s, jsonAssertions: [] })));
    assert.deepEqual(removed.payload, { jsonAssertions: [] });
  });

  describe('endpoint secret', () => {
    it('blank keeps the existing secret for the same auth type', () => {
      const result = expectOk(update(endpoint({ authType: 'bearer_token' })));
      assert.equal('authSecret' in result.payload, false);
    });

    it('a typed secret replaces it', () => {
      const result = expectOk(update(endpoint({ authType: 'bearer_token' }), (s) => ({ ...s, authSecret: ' new ' })));
      assert.deepEqual(result.payload, { authSecret: 'new' });
    });

    it('is required when auth is newly set', () => {
      const errors = expectErrors(update(endpoint(), (s) => ({ ...s, authType: 'bearer_token' })));
      assert.ok(errors.authSecret);
    });

    it('is required when the auth type changes', () => {
      const errors = expectErrors(
        update(endpoint({ authType: 'bearer_token' }), (s) => ({ ...s, authType: 'basic_auth', authUsername: 'u' })),
      );
      assert.ok(errors.authSecret);
      const ok = expectOk(
        update(endpoint({ authType: 'bearer_token' }), (s) => ({
          ...s,
          authType: 'basic_auth',
          authUsername: 'u',
          authSecret: 'pw',
        })),
      );
      assert.deepEqual(ok.payload, { authType: 'basic_auth', authUsername: 'u', authSecret: 'pw' });
    });

    it('switching auth off sends authType none and no secret', () => {
      const result = expectOk(
        update(endpoint({ authType: 'custom_header', authHeaderName: 'X-Key' }), (s) => ({ ...s, authType: 'none' })),
      );
      assert.deepEqual(result.payload, { authType: 'none', authHeaderName: null });
    });
  });

  describe('Health Standard', () => {
    it('turning it on keeps the saved status code even if the hidden field is invalid', () => {
      const result = expectOk(
        update(endpoint({ expectedStatusCode: 204 }), (s) => ({ ...s, healthStandard: true, expectedStatusCode: '' })),
      );
      assert.deepEqual(result.payload, { healthStandard: true });
    });

    it('turning it off validates the status code again', () => {
      const errors = expectErrors(
        update(endpoint({ healthStandard: true }), (s) => ({ ...s, healthStandard: false, expectedStatusCode: '' })),
      );
      assert.ok(errors.expectedStatusCode);
    });
  });

  it('switching to TCP clears the HTTP-only settings', () => {
    const original = endpoint({
      authType: 'bearer_token',
      healthStandard: true,
      jsonAssertions: [{ path: 'a', expectedValue: '1', matchMode: 'exact' }],
    });
    const result = expectOk(update(original, (s) => ({ ...s, checkType: 'tcp', url: 'tcp://db:5432' })));
    assert.deepEqual(result.payload, {
      url: 'tcp://db:5432',
      checkType: 'tcp',
      jsonAssertions: [],
      authType: 'none',
      healthStandard: false,
    });
  });

  describe('version check', () => {
    it('blank version secret keeps the stored one for the same auth type', () => {
      const original = endpoint({ versionCheck: versionConfig({ authType: 'bearer_token' }) });
      const result = expectOk(update(original, (s) => ({ ...s, version: { ...s.version, everyNChecks: '7' } })));
      assert.deepEqual(result.payload, {
        versionCheck: { ...versionConfig({ authType: 'bearer_token' }), everyNChecks: 7 },
      });
    });

    it('a new version secret is sent on its own when the config is unchanged', () => {
      const original = endpoint({ versionCheck: versionConfig({ authType: 'bearer_token' }) });
      const result = expectOk(update(original, (s) => ({ ...s, version: { ...s.version, secret: ' v2 ' } })));
      assert.deepEqual(result.payload, { versionAuthSecret: 'v2' });
    });

    it('requires a version secret when version auth is newly set or its type changes', () => {
      const none = endpoint({ versionCheck: versionConfig() });
      assert.ok(
        expectErrors(update(none, (s) => ({ ...s, version: { ...s.version, authType: 'bearer_token' } }))).versionSecret,
      );
      const bearer = endpoint({ versionCheck: versionConfig({ authType: 'bearer_token' }) });
      assert.ok(
        expectErrors(
          update(bearer, (s) => ({ ...s, version: { ...s.version, authType: 'custom_header', authHeaderName: 'X' } })),
        ).versionSecret,
      );
    });

    it('the endpoint secret and version secret are independent', () => {
      // Endpoint auth unchanged (blank keeps), version auth newly set (secret required).
      const original = endpoint({ authType: 'bearer_token', versionCheck: versionConfig() });
      const errors = expectErrors(
        update(original, (s) => ({ ...s, version: { ...s.version, authType: 'bearer_token' } })),
      );
      assert.ok(errors.versionSecret);
      assert.equal(errors.authSecret, undefined);
    });

    it('enabling a new version check on an existing endpoint', () => {
      const result = expectOk(
        update(endpoint(), (s) => ({
          ...s,
          version: { ...s.version, isEnabled: true, url: 'https://x.example.com/v', versionFieldPath: 'v' },
        })),
      );
      assert.deepEqual(result.payload, {
        versionCheck: versionConfig({ url: 'https://x.example.com/v', versionFieldPath: 'v' }),
      });
    });

    it('disabling keeps the config, paused', () => {
      const original = endpoint({ versionCheck: versionConfig({ authType: 'bearer_token' }) });
      const result = expectOk(update(original, (s) => ({ ...s, version: { ...s.version, isEnabled: false } })));
      assert.deepEqual(result.payload, {
        versionCheck: versionConfig({ isEnabled: false, authType: 'bearer_token' }),
      });
    });

    it('re-enabling a paused config with a stored secret needs no retyping', () => {
      const original = endpoint({ versionCheck: versionConfig({ isEnabled: false, authType: 'bearer_token' }) });
      const result = expectOk(update(original, (s) => ({ ...s, version: { ...s.version, isEnabled: true } })));
      assert.deepEqual(result.payload, { versionCheck: versionConfig({ authType: 'bearer_token' }) });
    });

    it('a disabled config whose URL was cleared is removed (null)', () => {
      const original = endpoint({ versionCheck: versionConfig() });
      const result = expectOk(
        update(original, (s) => ({ ...s, version: { ...s.version, isEnabled: false, url: '' } })),
      );
      assert.deepEqual(result.payload, { versionCheck: null });
    });

    it('an untouched paused config is not resent', () => {
      const original = endpoint({ versionCheck: versionConfig({ isEnabled: false }) });
      assert.deepEqual(expectOk(update(original)).payload, {});
    });

    it('switching version auth to none sends the config (the backend drops its secret)', () => {
      const original = endpoint({ versionCheck: versionConfig({ authType: 'basic_auth', authUsername: 'u' }) });
      const result = expectOk(update(original, (s) => ({ ...s, version: { ...s.version, authType: 'none', secret: 'x' } })));
      assert.deepEqual(result.payload, { versionCheck: versionConfig() });
    });
  });
});

// ── Backend errors ──

describe('describeApiError', () => {
  it('passes a plain error string through', () => {
    assert.deepEqual(describeApiError({ error: 'Endpoint not found' }, 'fallback'), ['Endpoint not found']);
  });

  it('names each zod field error', () => {
    assert.deepEqual(
      describeApiError(
        {
          error: {
            formErrors: ['Invalid body'],
            fieldErrors: {
              checkInterval: ['Number must be greater than or equal to 30'],
              versionCheck: ['Must be an http(s) URL'],
              somethingNew: ['Required'],
            },
          },
        },
        'fallback',
      ),
      [
        'Invalid body',
        'Check interval: Number must be greater than or equal to 30',
        'Version check: Must be an http(s) URL',
        'somethingNew: Required',
      ],
    );
  });

  it('falls back for unknown shapes', () => {
    assert.deepEqual(describeApiError(undefined, 'Request failed (500)'), ['Request failed (500)']);
    assert.deepEqual(describeApiError({ message: 'x' }, 'fb'), ['fb']);
    assert.deepEqual(describeApiError({ error: { fieldErrors: {} } }, 'fb'), ['fb']);
    assert.deepEqual(describeApiError({ error: '' }, 'fb'), ['fb']);
    assert.deepEqual(describeApiError({ error: 42 }, 'fb'), ['fb']);
  });
});
