import { Pressable, StyleSheet, Text, View } from 'react-native';
import { Ionicons } from '@expo/vector-icons';
import { colors } from '../theme/colors';
import type { DashboardEndpoint } from '../api/dashboard';
import type { HealthStatus } from '../api/endpoints';
import { deriveStatus } from '../logic/status';
import { StatusBadge } from './StatusBadge';

export interface EndpointCardData {
  id: string;
  name: string;
  url: string;
  isPaused: boolean;
  isHealthy: boolean | null;
  isDegraded?: boolean | null;
  healthStatus?: HealthStatus | null;
  responseTimeMs?: number | null;
  /** Down or warn reason of the latest check; shown for degraded and unhealthy endpoints. */
  reason?: string | null;
}

/** Card data from a dashboard entry (status, degraded flag, response time and reason). */
export function cardDataFromDashboard(
  endpoint: Pick<DashboardEndpoint, 'id' | 'name' | 'url' | 'isPaused' | 'latestCheck'>,
): EndpointCardData {
  return {
    id: endpoint.id,
    name: endpoint.name,
    url: endpoint.url,
    isPaused: endpoint.isPaused,
    isHealthy: endpoint.latestCheck?.isHealthy ?? null,
    isDegraded: endpoint.latestCheck?.isDegraded ?? null,
    healthStatus: endpoint.latestCheck?.healthStatus ?? null,
    responseTimeMs: endpoint.latestCheck?.responseTimeMs,
    reason: endpoint.latestCheck?.failureReason ?? null,
  };
}

interface EndpointCardProps {
  endpoint: EndpointCardData;
  onPress?: () => void;
}

export function EndpointCard({ endpoint, onPress }: EndpointCardProps) {
  const status = deriveStatus(endpoint);
  const showReason = (status === 'degraded' || status === 'unhealthy') && !!endpoint.reason;

  return (
    <Pressable
      onPress={onPress}
      style={({ pressed }) => [styles.card, pressed && styles.cardPressed]}
    >
      <View style={styles.info}>
        <Text style={styles.name} numberOfLines={1}>
          {endpoint.name}
        </Text>
        <Text style={styles.url} numberOfLines={1}>
          {endpoint.url}
        </Text>
        <View style={styles.metaRow}>
          <StatusBadge status={status} />
          {endpoint.responseTimeMs != null && (
            <Text style={styles.responseTime}>{endpoint.responseTimeMs} ms</Text>
          )}
        </View>
        {showReason ? (
          <Text style={[styles.reason, { color: colors[status] }]} numberOfLines={2}>
            {endpoint.reason}
          </Text>
        ) : null}
      </View>
      <Ionicons name="chevron-forward" size={20} color={colors.textSecondary} />
    </Pressable>
  );
}

const styles = StyleSheet.create({
  card: {
    flexDirection: 'row',
    alignItems: 'center',
    backgroundColor: colors.card,
    borderRadius: 12,
    borderWidth: 1,
    borderColor: colors.border,
    padding: 14,
    gap: 8,
  },
  cardPressed: {
    opacity: 0.7,
  },
  info: {
    flex: 1,
    gap: 4,
  },
  name: {
    fontSize: 16,
    fontWeight: '600',
    color: colors.text,
  },
  url: {
    fontSize: 13,
    color: colors.textSecondary,
  },
  metaRow: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 10,
    marginTop: 4,
  },
  reason: {
    fontSize: 12,
  },
  responseTime: {
    fontSize: 12,
    color: colors.textSecondary,
  },
});
