import {
  pgTable,
  uuid,
  text,
  integer,
  boolean,
  timestamp,
  date,
  jsonb,
  numeric,
  uniqueIndex,
  index,
} from 'drizzle-orm/pg-core';
import type { InferSelectModel, InferInsertModel } from 'drizzle-orm';

// ── Users & Auth ──

export const users = pgTable('users', {
  id: uuid('id').defaultRandom().primaryKey(),
  email: text('email').notNull().unique(),
  passwordHash: text('password_hash').notNull(),
  name: text('name').notNull(),
  role: text('role', { enum: ['admin', 'member'] }).notNull().default('member'),
  createdAt: timestamp('created_at', { withTimezone: true }).defaultNow().notNull(),
  updatedAt: timestamp('updated_at', { withTimezone: true }).defaultNow().notNull(),
});

export const invitations = pgTable('invitations', {
  id: uuid('id').defaultRandom().primaryKey(),
  email: text('email').notNull(),
  invitedById: uuid('invited_by_id')
    .notNull()
    .references(() => users.id),
  tokenHash: text('token_hash').notNull().unique(),
  expiresAt: timestamp('expires_at', { withTimezone: true }).notNull(),
  acceptedAt: timestamp('accepted_at', { withTimezone: true }),
  createdAt: timestamp('created_at', { withTimezone: true }).defaultNow().notNull(),
});

export const refreshTokens = pgTable('refresh_tokens', {
  id: uuid('id').defaultRandom().primaryKey(),
  userId: uuid('user_id')
    .notNull()
    .references(() => users.id, { onDelete: 'cascade' }),
  tokenHash: text('token_hash').notNull().unique(),
  expiresAt: timestamp('expires_at', { withTimezone: true }).notNull(),
  revokedAt: timestamp('revoked_at', { withTimezone: true }),
  createdAt: timestamp('created_at', { withTimezone: true }).defaultNow().notNull(),
});

// ── Endpoints ──

export const endpoints = pgTable(
  'endpoints',
  {
    id: uuid('id').defaultRandom().primaryKey(),
    userId: uuid('user_id')
      .notNull()
      .references(() => users.id, { onDelete: 'cascade' }),
    name: text('name').notNull(),
    url: text('url').notNull(),
    checkType: text('check_type', { enum: ['http', 'tcp'] }).notNull().default('http'),
    expectedStatusCode: integer('expected_status_code').notNull().default(200),
    checkInterval: integer('check_interval').notNull().default(300),
    groupName: text('group_name'),
    jsonAssertions: jsonb('json_assertions').$type<JsonAssertion[]>().notNull().default([]),
    authType: text('auth_type', {
      enum: ['none', 'bearer_token', 'basic_auth', 'custom_header'],
    })
      .notNull()
      .default('none'),
    authUsername: text('auth_username'),
    authHeaderName: text('auth_header_name'),
    isPaused: boolean('is_paused').notNull().default(false),
    /** Optional periodic version check against a separate URL — see `VersionCheckConfig`. */
    versionCheck: jsonb('version_check').$type<VersionCheckConfig>(),
    /** Endpoint implements the Zext Health Standard (`zext-health/v1`) — see `health-standard.ts`. */
    healthStandard: boolean('health_standard').notNull().default(false),
    createdAt: timestamp('created_at', { withTimezone: true }).defaultNow().notNull(),
    updatedAt: timestamp('updated_at', { withTimezone: true }).defaultNow().notNull(),
  },
  (table) => [index('endpoints_user_id_idx').on(table.userId)],
);

export const endpointSecrets = pgTable('endpoint_secrets', {
  id: uuid('id').defaultRandom().primaryKey(),
  endpointId: uuid('endpoint_id')
    .notNull()
    .references(() => endpoints.id, { onDelete: 'cascade' })
    .unique(),
  encryptedValue: text('encrypted_value').notNull(),
  iv: text('iv').notNull(),
  createdAt: timestamp('created_at', { withTimezone: true }).defaultNow().notNull(),
  updatedAt: timestamp('updated_at', { withTimezone: true }).defaultNow().notNull(),
});

/** Secret for the version check's own auth — kept apart from `endpoint_secrets` so the two never collide. */
export const endpointVersionSecrets = pgTable('endpoint_version_secrets', {
  id: uuid('id').defaultRandom().primaryKey(),
  endpointId: uuid('endpoint_id')
    .notNull()
    .references(() => endpoints.id, { onDelete: 'cascade' })
    .unique(),
  encryptedValue: text('encrypted_value').notNull(),
  iv: text('iv').notNull(),
  createdAt: timestamp('created_at', { withTimezone: true }).defaultNow().notNull(),
  updatedAt: timestamp('updated_at', { withTimezone: true }).defaultNow().notNull(),
});

// ── Version Checks ──

/** Per-endpoint cadence counter plus the latest version check result. */
export const endpointVersionState = pgTable('endpoint_version_state', {
  endpointId: uuid('endpoint_id')
    .primaryKey()
    .references(() => endpoints.id, { onDelete: 'cascade' }),
  /** Health checks run since the version check config last changed; drives "every N checks". */
  checkCounter: integer('check_counter').notNull().default(0),
  lastCheckedAt: timestamp('last_checked_at', { withTimezone: true }),
  lastIsSuccess: boolean('last_is_success'),
  lastVersion: text('last_version'),
  lastFailureReason: text('last_failure_reason'),
  lastStatusCode: integer('last_status_code'),
  lastResponseTimeMs: integer('last_response_time_ms'),
});

/** Distinct versions seen over time (consecutive repeats collapse into one row). Capped per endpoint. */
export const versionHistory = pgTable(
  'version_history',
  {
    id: uuid('id').defaultRandom().primaryKey(),
    endpointId: uuid('endpoint_id')
      .notNull()
      .references(() => endpoints.id, { onDelete: 'cascade' }),
    value: text('value').notNull(),
    firstSeenAt: timestamp('first_seen_at', { withTimezone: true }).notNull(),
    lastSeenAt: timestamp('last_seen_at', { withTimezone: true }).notNull(),
  },
  (table) => [index('version_history_endpoint_first_seen_idx').on(table.endpointId, table.firstSeenAt)],
);

// ── Health Standard ──

/**
 * Latest parsed health-standard response per endpoint. Only the newest component list is kept
 * (overwritten on every check) so component checks never bloat the per-result history.
 */
export const endpointHealthState = pgTable('endpoint_health_state', {
  endpointId: uuid('endpoint_id')
    .primaryKey()
    .references(() => endpoints.id, { onDelete: 'cascade' }),
  checkedAt: timestamp('checked_at', { withTimezone: true }).notNull(),
  status: text('status', { enum: ['pass', 'warn', 'fail'] }).notNull(),
  version: text('version'),
  releaseId: text('release_id'),
  output: text('output'),
  components: jsonb('components').$type<HealthComponent[]>().notNull().default([]),
});

// ── Health Checks ──

export const healthCheckResults = pgTable(
  'health_check_results',
  {
    id: uuid('id').defaultRandom().primaryKey(),
    endpointId: uuid('endpoint_id')
      .notNull()
      .references(() => endpoints.id, { onDelete: 'cascade' }),
    timestamp: timestamp('timestamp', { withTimezone: true }).defaultNow().notNull(),
    isHealthy: boolean('is_healthy').notNull(),
    responseTimeMs: integer('response_time_ms'),
    statusCode: integer('status_code'),
    failureReason: text('failure_reason'),
    certificateExpiresAt: timestamp('certificate_expires_at', { withTimezone: true }),
    /** Standard `status` ('pass' | 'warn' | 'fail') for health-standard endpoints, `null` otherwise. */
    healthStatus: text('health_status', { enum: ['pass', 'warn', 'fail'] }),
  },
  (table) => [index('hcr_endpoint_timestamp_idx').on(table.endpointId, table.timestamp)],
);

// ── Daily Stats ──

export const dailyStats = pgTable(
  'daily_stats',
  {
    id: uuid('id').defaultRandom().primaryKey(),
    endpointId: uuid('endpoint_id')
      .notNull()
      .references(() => endpoints.id, { onDelete: 'cascade' }),
    date: date('date').notNull(),
    totalChecks: integer('total_checks').notNull().default(0),
    downChecks: integer('down_checks').notNull().default(0),
    downtimeSeconds: numeric('downtime_seconds').notNull().default('0'),
  },
  (table) => [uniqueIndex('daily_stats_endpoint_date_idx').on(table.endpointId, table.date)],
);

// ── Incidents ──

export const incidents = pgTable(
  'incidents',
  {
    id: uuid('id').defaultRandom().primaryKey(),
    endpointId: uuid('endpoint_id')
      .notNull()
      .references(() => endpoints.id, { onDelete: 'cascade' }),
    startedAt: timestamp('started_at', { withTimezone: true }).notNull(),
    endedAt: timestamp('ended_at', { withTimezone: true }),
    failureReason: text('failure_reason'),
    isOngoing: boolean('is_ongoing').notNull().default(true),
  },
  (table) => [index('incidents_endpoint_ongoing_idx').on(table.endpointId, table.isOngoing)],
);

// ── Notifications ──

export const pushSubscriptions = pgTable('push_subscriptions', {
  id: uuid('id').defaultRandom().primaryKey(),
  userId: uuid('user_id')
    .notNull()
    .references(() => users.id, { onDelete: 'cascade' }),
  platform: text('platform', { enum: ['apns', 'fcm', 'web'] }).notNull(),
  token: text('token').notNull(),
  deviceName: text('device_name'),
  createdAt: timestamp('created_at', { withTimezone: true }).defaultNow().notNull(),
});

export const notificationPreferences = pgTable('notification_preferences', {
  id: uuid('id').defaultRandom().primaryKey(),
  userId: uuid('user_id')
    .notNull()
    .references(() => users.id, { onDelete: 'cascade' })
    .unique(),
  notifyOnDown: boolean('notify_on_down').notNull().default(true),
  notifyOnRecovery: boolean('notify_on_recovery').notNull().default(true),
  notifyOnVersionChange: boolean('notify_on_version_change').notNull().default(true),
  createdAt: timestamp('created_at', { withTimezone: true }).defaultNow().notNull(),
  updatedAt: timestamp('updated_at', { withTimezone: true }).defaultNow().notNull(),
});

// ── Types ──

export interface JsonAssertion {
  path: string;
  expectedValue: string;
  matchMode: 'exact' | 'contains' | 'regex';
}

export type AuthType = 'none' | 'bearer_token' | 'basic_auth' | 'custom_header';

export interface VersionCheckConfig {
  isEnabled: boolean;
  url: string;
  everyNChecks: number;
  /** Dot-path to the version value in the JSON body, e.g. "data.version". */
  versionFieldPath: string;
  assertions: JsonAssertion[];
  authType: AuthType;
  authUsername: string | null;
  authHeaderName: string | null;
}

export type HealthStatus = 'pass' | 'warn' | 'fail';

/** One flattened entry of a health-standard `checks` map (`key` is the `component:measurement` name). */
export interface HealthComponent {
  key: string;
  status: HealthStatus;
  componentId?: string;
  componentType?: string;
  observedValue?: number | string | boolean;
  observedUnit?: string;
  time?: string;
  output?: string;
}

export type User = InferSelectModel<typeof users>;
export type NewUser = InferInsertModel<typeof users>;
export type Endpoint = InferSelectModel<typeof endpoints>;
export type NewEndpoint = InferInsertModel<typeof endpoints>;
export type HealthCheckResult = InferSelectModel<typeof healthCheckResults>;
export type NewHealthCheckResult = InferInsertModel<typeof healthCheckResults>;
export type DailyStat = InferSelectModel<typeof dailyStats>;
export type Incident = InferSelectModel<typeof incidents>;
export type RefreshToken = InferSelectModel<typeof refreshTokens>;
export type EndpointVersionState = InferSelectModel<typeof endpointVersionState>;
export type VersionHistoryEntry = InferSelectModel<typeof versionHistory>;
export type EndpointHealthState = InferSelectModel<typeof endpointHealthState>;
