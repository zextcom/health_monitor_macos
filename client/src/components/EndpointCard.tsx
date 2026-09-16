import { Pressable, StyleSheet, Text, View } from 'react-native';
import { Ionicons } from '@expo/vector-icons';
import { colors } from '../theme/colors';
import { StatusBadge, statusFromEndpoint } from './StatusBadge';

export interface EndpointCardData {
  id: string;
  name: string;
  url: string;
  isPaused: boolean;
  isHealthy: boolean | null;
  responseTimeMs?: number | null;
}

interface EndpointCardProps {
  endpoint: EndpointCardData;
  onPress?: () => void;
}

export function EndpointCard({ endpoint, onPress }: EndpointCardProps) {
  const status = statusFromEndpoint(endpoint);

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
  responseTime: {
    fontSize: 12,
    color: colors.textSecondary,
  },
});
