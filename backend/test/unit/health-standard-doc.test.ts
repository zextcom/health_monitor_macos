import { describe, it, expect } from 'vitest';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { HEALTH_STANDARD_EXAMPLES, HEALTH_STANDARD_RULES, HTTP_STATUS_FOR, isHealthStatus } from '../../src/modules/standards/health-standard.js';
import { validateHealthResponse } from '../../src/modules/standards/health-standard-validator.js';

/**
 * docs/health-standard.md is handed to other teams as-is, while the API serves the module's
 * content. These tests keep the two from drifting: every ```json block in the doc must be a valid
 * body, and the module's pass/warn/fail examples must appear in the doc verbatim (as JSON).
 * Counter-examples in the doc use ```text so they're skipped here.
 */

const docPath = fileURLToPath(new URL('../../../docs/health-standard.md', import.meta.url));
const doc = readFileSync(docPath, 'utf8');
const jsonBlocks = [...doc.matchAll(/```json\n([\s\S]*?)```/g)].map((match) => JSON.parse(match[1]) as Record<string, unknown>);

describe('docs/health-standard.md', () => {
  it('has JSON examples', () => {
    expect(jsonBlocks.length).toBeGreaterThanOrEqual(5);
  });

  it('every JSON example is a valid body (no MUST violations)', () => {
    for (const body of jsonBlocks) {
      expect(isHealthStatus(body.status)).toBe(true);
      const report = validateHealthResponse({
        httpStatus: HTTP_STATUS_FOR[body.status as 'pass' | 'warn' | 'fail'],
        body,
      });
      expect(report.errors, JSON.stringify(body)).toEqual([]);
      expect(report.valid).toBe(true);
    }
  });

  it('contains the published pass/warn/fail examples', () => {
    for (const example of Object.values(HEALTH_STANDARD_EXAMPLES)) {
      expect(jsonBlocks).toContainEqual(example.body);
    }
  });

  it('documents the HTTP status lines of the published examples', () => {
    expect(doc).toContain('HTTP/1.1 200 OK');
    expect(doc).toContain('HTTP/1.1 503 Service Unavailable');
  });

  it('mentions every field the schema defines and every MUST-level topic', () => {
    for (const field of ['status', 'version', 'releaseId', 'serviceId', 'description', 'notes', 'output', 'checks',
      'componentId', 'componentType', 'observedValue', 'observedUnit', 'time']) {
      expect(doc).toContain(`\`${field}\``);
    }
    expect(HEALTH_STANDARD_RULES.filter((rule) => rule.level === 'must').length).toBeGreaterThan(0);
    expect(doc).toContain('zext-health/v1');
    expect(doc).toContain('application/health+json');
  });
});
