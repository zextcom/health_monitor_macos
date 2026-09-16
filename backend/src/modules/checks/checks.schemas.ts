import { z } from 'zod';

export const checkParamsSchema = z.object({
  id: z.string().uuid(),
});

export const checkHistoryQuerySchema = z.object({
  limit: z.coerce.number().int().min(1).max(1000).default(100),
  offset: z.coerce.number().int().min(0).default(0),
});

export const dailyStatsQuerySchema = z.object({
  days: z.coerce.number().int().min(1).max(365).default(30),
});

export const uptimeQuerySchema = z.object({
  days: z.coerce.number().int().min(1).max(365).default(7),
});

export const incidentsQuerySchema = z.object({
  limit: z.coerce.number().int().min(1).max(100).default(20),
});

export type CheckParams = z.infer<typeof checkParamsSchema>;
export type CheckHistoryQuery = z.infer<typeof checkHistoryQuerySchema>;
export type DailyStatsQuery = z.infer<typeof dailyStatsQuerySchema>;
export type UptimeQuery = z.infer<typeof uptimeQuerySchema>;
export type IncidentsQuery = z.infer<typeof incidentsQuerySchema>;
