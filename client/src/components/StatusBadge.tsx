import { StyleSheet, Text, View } from 'react-native';
import { colors } from '../theme/colors';

export type Status = 'healthy' | 'unhealthy' | 'paused' | 'unknown';

interface StatusBadgeProps {
  status: Status;
}

const LABELS: Record<Status, string> = {
  healthy: 'Healthy',
  unhealthy: 'Unhealthy',
  paused: 'Paused',
  unknown: 'Unknown',
};

export function StatusBadge({ status }: StatusBadgeProps) {
  const color = colors[status];

  return (
    <View style={[styles.badge, { backgroundColor: `${color}1a`, borderColor: color }]}>
      <View style={[styles.dot, { backgroundColor: color }]} />
      <Text style={[styles.label, { color }]}>{LABELS[status]}</Text>
    </View>
  );
}

export function statusFromEndpoint(input: { isPaused: boolean; isHealthy: boolean | null }): Status {
  if (input.isPaused) return 'paused';
  if (input.isHealthy === null) return 'unknown';
  return input.isHealthy ? 'healthy' : 'unhealthy';
}

const styles = StyleSheet.create({
  badge: {
    flexDirection: 'row',
    alignItems: 'center',
    alignSelf: 'flex-start',
    paddingHorizontal: 8,
    paddingVertical: 4,
    borderRadius: 999,
    borderWidth: 1,
    gap: 6,
  },
  dot: {
    width: 6,
    height: 6,
    borderRadius: 3,
  },
  label: {
    fontSize: 12,
    fontWeight: '600',
  },
});
