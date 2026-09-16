import { z } from 'zod';

const jsonAssertionSchema = z.object({
  path: z.string(),
  expectedValue: z.string(),
  matchMode: z.enum(['exact', 'contains', 'regex']).default('exact'),
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

export type CreateEndpointInput = z.infer<typeof createEndpointSchema>;
export type UpdateEndpointInput = z.infer<typeof updateEndpointSchema>;
export type ImportEndpointInput = z.infer<typeof importEndpointSchema>;
export type ImportInput = z.infer<typeof importSchema>;
export type ListEndpointsQuery = z.infer<typeof listEndpointsQuerySchema>;
export type EndpointParams = z.infer<typeof endpointParamsSchema>;
