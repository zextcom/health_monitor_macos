import { z } from 'zod';

const jsonAssertionSchema = z.object({
  path: z.string(),
  expectedValue: z.string(),
  matchMode: z.enum(['exact', 'contains', 'regex']).default('exact'),
});

const httpUrl = z
  .string()
  .url()
  .refine((value) => /^https?:\/\//i.test(value), 'Must be an http(s) URL');

export const versionCheckSchema = z.object({
  isEnabled: z.boolean().default(true),
  url: httpUrl,
  everyNChecks: z.number().int().min(1).max(1000).default(5),
  versionFieldPath: z.string().trim().min(1),
  assertions: z.array(jsonAssertionSchema).default([]),
  authType: z.enum(['none', 'bearer_token', 'basic_auth', 'custom_header']).default('none'),
  authUsername: z.string().nullable().default(null),
  authHeaderName: z.string().nullable().default(null),
});

export const createEndpointSchema = z.object({
  name: z.string().min(1).max(255),
  url: z.string().min(1),
  checkType: z.enum(['http', 'tcp']).default('http'),
  expectedStatusCode: z.number().int().min(100).max(599).default(200),
  checkInterval: z.number().int().min(30).max(86400).default(300),
  groupName: z.string().max(100).nullable().optional(),
  jsonAssertions: z.array(jsonAssertionSchema).default([]),
  authType: z.enum(['none', 'bearer_token', 'basic_auth', 'custom_header']).default('none'),
  authUsername: z.string().nullable().optional(),
  authHeaderName: z.string().nullable().optional(),
  authSecret: z.string().optional(),
  /** `null` removes the version check (and its secret). */
  versionCheck: versionCheckSchema.nullable().optional(),
  /** Secret for `versionCheck.authType` — stored encrypted, never returned. */
  versionAuthSecret: z.string().optional(),
  /** Evaluate responses per the Zext Health Standard (`zext-health/v1`) instead of `expectedStatusCode`. */
  healthStandard: z.boolean().default(false),
});

export const updateEndpointSchema = createEndpointSchema.partial();

const importJsonAssertionSchema = z.object({
  path: z.string(),
  expectedValue: z.string(),
  matchMode: z.enum(['exact', 'contains', 'regex']).optional().default('exact'),
});

export const importEndpointSchema = z
  .object({
    id: z.string().uuid().optional(),
    name: z.string(),
    url: z.string(),
    checkType: z.enum(['http', 'tcp']).optional().default('http'),
    expectedStatusCode: z.number().optional().default(200),
    checkIntervalOverride: z.number().nullable().optional(),
    group: z.string().nullable().optional(),
    jsonAssertions: z.array(importJsonAssertionSchema).optional().default([]),
    authType: z
      .enum(['none', 'bearerToken', 'basicAuth', 'customHeader'])
      .optional()
      .default('none'),
    authUsername: z.string().nullable().optional(),
    authHeaderName: z.string().nullable().optional(),
    healthStandard: z.boolean().optional().default(false),
    // macOS export shape: camelCase auth enum, no secrets.
    versionCheck: z
      .object({
        isEnabled: z.boolean().optional().default(true),
        url: httpUrl,
        everyNChecks: z.number().int().min(1).max(1000).optional().default(5),
        versionFieldPath: z.string(),
        assertions: z.array(importJsonAssertionSchema).optional().default([]),
        authType: z
          .enum(['none', 'bearerToken', 'basicAuth', 'customHeader'])
          .optional()
          .default('none'),
        authUsername: z.string().nullable().optional(),
        authHeaderName: z.string().nullable().optional(),
      })
      .nullable()
      .optional(),
  })
  .passthrough();

export const importSchema = z.array(importEndpointSchema);

export const listEndpointsQuerySchema = z.object({
  group: z.string().optional(),
  paused: z.enum(['true', 'false']).optional(),
});

export const endpointParamsSchema = z.object({
  id: z.string().uuid(),
});

export type VersionCheckInput = z.infer<typeof versionCheckSchema>;
export type CreateEndpointInput = z.infer<typeof createEndpointSchema>;
export type UpdateEndpointInput = z.infer<typeof updateEndpointSchema>;
export type ImportEndpointInput = z.infer<typeof importEndpointSchema>;
export type ImportInput = z.infer<typeof importSchema>;
export type ListEndpointsQuery = z.infer<typeof listEndpointsQuerySchema>;
export type EndpointParams = z.infer<typeof endpointParamsSchema>;
