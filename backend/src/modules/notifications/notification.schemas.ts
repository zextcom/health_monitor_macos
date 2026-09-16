import { z } from 'zod';

export const updatePreferencesSchema = z.object({
  notifyOnDown: z.boolean().optional(),
  notifyOnRecovery: z.boolean().optional(),
});

export const createSubscriptionSchema = z.object({
  platform: z.enum(['apns', 'fcm', 'web']),
  token: z.string().min(1),
  deviceName: z.string().max(255).nullable().optional(),
});

export const subscriptionParamsSchema = z.object({
  id: z.string().uuid(),
});

export type UpdatePreferencesInput = z.infer<typeof updatePreferencesSchema>;
export type CreateSubscriptionInput = z.infer<typeof createSubscriptionSchema>;
export type SubscriptionParams = z.infer<typeof subscriptionParamsSchema>;
