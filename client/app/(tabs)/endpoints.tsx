import { useCallback, useState } from 'react';
import { FlatList, Pressable, RefreshControl, StyleSheet, Text, View } from 'react-native';
import { useRouter } from 'expo-router';
import { Ionicons } from '@expo/vector-icons';
import { colors } from '../../src/theme/colors';
import { listEndpoints, type Endpoint } from '../../src/api/endpoints';
import { getDashboard, type DashboardResponse } from '../../src/api/dashboard';
import { ApiError } from '../../src/api/client';
import { EndpointCard, cardDataFromDashboard } from '../../src/components/EndpointCard';
import { EmptyState } from '../../src/components/EmptyState';
import { useRefreshOnFocus } from '../../src/hooks/useRefreshOnFocus';
import { useSSE } from '../../src/hooks/useSSE';
import { applyCheckEvent } from '../../src/logic/status';

export default function EndpointsScreen() {
  const router = useRouter();
  const [endpoints, setEndpoints] = useState<Endpoint[]>([]);
  // The endpoint list has no check results; the dashboard supplies each one's status. Optional:
  // the list still renders (with unknown status) if it fails.
  const [dashboard, setDashboard] = useState<DashboardResponse | null>(null);
  const [isLoading, setIsLoading] = useState(true);
  const [refreshing, setRefreshing] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const fetchEndpoints = useCallback(async () => {
    try {
      setError(null);
      const [result, dashboardResult] = await Promise.all([
        listEndpoints(),
        getDashboard().catch(() => null),
      ]);
      setEndpoints(result);
      setDashboard(dashboardResult);
    } catch (err) {
      setError(err instanceof ApiError ? err.message : 'Failed to load endpoints');
    } finally {
      setIsLoading(false);
      setRefreshing(false);
    }
  }, []);

  useRefreshOnFocus(fetchEndpoints);

  useSSE(
    useCallback((event) => {
      setDashboard((current) => (current ? applyCheckEvent(current, event) : current));
    }, []),
  );

  const onRefresh = useCallback(() => {
    setRefreshing(true);
    fetchEndpoints();
  }, [fetchEndpoints]);

  if (isLoading) {
    return (
      <View style={styles.centered}>
        <Text style={styles.loadingText}>Loading endpoints…</Text>
      </View>
    );
  }

  const dashboardById = new Map((dashboard?.endpoints ?? []).map((entry) => [entry.id, entry]));
  const openAddForm = () => router.push('/endpoint-form');

  return (
    <FlatList
      style={styles.container}
      contentContainerStyle={styles.content}
      data={endpoints}
      keyExtractor={(item) => item.id}
      refreshControl={<RefreshControl refreshing={refreshing} onRefresh={onRefresh} />}
      ListHeaderComponent={
        <View style={styles.headerSection}>
          <View style={styles.headingRow}>
            <Text style={styles.heading}>Endpoints</Text>
            <Pressable
              onPress={openAddForm}
              style={({ pressed }) => [styles.addButton, pressed && styles.addButtonPressed]}
              accessibilityRole="button"
              accessibilityLabel="Add endpoint"
            >
              <Ionicons name="add" size={18} color="#fff" />
              <Text style={styles.addButtonText}>Add</Text>
            </Pressable>
          </View>
          {error ? (
            <View style={styles.errorBox}>
              <Text style={styles.errorText}>{error}</Text>
            </View>
          ) : null}
        </View>
      }
      renderItem={({ item }) => (
        <EndpointCard
          endpoint={cardDataFromDashboard({
            ...item,
            latestCheck: dashboardById.get(item.id)?.latestCheck ?? null,
          })}
          onPress={() => router.push(`/endpoints/${item.id}`)}
        />
      )}
      ItemSeparatorComponent={() => <View style={styles.separator} />}
      ListEmptyComponent={
        <EmptyState
          icon="link-outline"
          title="No endpoints"
          message="Tap Add to start monitoring an endpoint."
        />
      }
    />
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: colors.background,
  },
  content: {
    padding: 16,
    gap: 12,
  },
  centered: {
    flex: 1,
    alignItems: 'center',
    justifyContent: 'center',
    backgroundColor: colors.background,
  },
  loadingText: {
    color: colors.textSecondary,
    fontSize: 15,
  },
  headerSection: {
    gap: 12,
    marginBottom: 4,
  },
  headingRow: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    gap: 12,
  },
  addButton: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 4,
    backgroundColor: colors.primary,
    borderRadius: 999,
    paddingHorizontal: 14,
    paddingVertical: 8,
  },
  addButtonPressed: {
    opacity: 0.8,
  },
  addButtonText: {
    color: '#fff',
    fontSize: 15,
    fontWeight: '600',
  },
  heading: {
    fontSize: 26,
    fontWeight: '700',
    color: colors.text,
  },
  separator: {
    height: 10,
  },
  errorBox: {
    backgroundColor: `${colors.unhealthy}1a`,
    borderColor: colors.unhealthy,
    borderWidth: 1,
    borderRadius: 10,
    padding: 12,
  },
  errorText: {
    color: colors.unhealthy,
    fontSize: 14,
  },
});
