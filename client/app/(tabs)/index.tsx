import { useCallback, useState } from 'react';
import { FlatList, RefreshControl, StyleSheet, Text, View } from 'react-native';
import { useRouter } from 'expo-router';
import { colors } from '../../src/theme/colors';
import { getDashboard, type DashboardResponse } from '../../src/api/dashboard';
import { ApiError } from '../../src/api/client';
import { StatCard } from '../../src/components/StatCard';
import { EndpointCard } from '../../src/components/EndpointCard';
import { EmptyState } from '../../src/components/EmptyState';
import { useRefreshOnFocus } from '../../src/hooks/useRefreshOnFocus';

export default function DashboardScreen() {
  const router = useRouter();
  const [data, setData] = useState<DashboardResponse | null>(null);
  const [isLoading, setIsLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [refreshing, setRefreshing] = useState(false);

  const fetchDashboard = useCallback(async () => {
    try {
      setError(null);
      const result = await getDashboard();
      setData(result);
    } catch (err) {
      setError(err instanceof ApiError ? err.message : 'Failed to load dashboard');
    } finally {
      setIsLoading(false);
      setRefreshing(false);
    }
  }, []);

  useRefreshOnFocus(fetchDashboard);

  const onRefresh = useCallback(() => {
    setRefreshing(true);
    fetchDashboard();
  }, [fetchDashboard]);

  if (isLoading) {
    return (
      <View style={styles.centered}>
        <Text style={styles.loadingText}>Loading dashboard…</Text>
      </View>
    );
  }

  const summary = data?.summary;

  return (
    <FlatList
      style={styles.container}
      contentContainerStyle={styles.content}
      data={data?.endpoints ?? []}
      keyExtractor={(item) => item.id}
      refreshControl={<RefreshControl refreshing={refreshing} onRefresh={onRefresh} />}
      ListHeaderComponent={
        <View style={styles.headerSection}>
          <Text style={styles.heading}>Dashboard</Text>

          {error ? (
            <View style={styles.errorBox}>
              <Text style={styles.errorText}>{error}</Text>
            </View>
          ) : null}

          {summary ? (
            <>
              <View style={styles.statsRow}>
                <StatCard label="Total" value={summary.totalEndpoints} />
                <StatCard label="Healthy" value={summary.healthyEndpoints} color={colors.healthy} />
                <StatCard label="Unhealthy" value={summary.unhealthyEndpoints} color={colors.unhealthy} />
              </View>
              <View style={styles.statsRow}>
                <StatCard label="Paused" value={summary.pausedEndpoints} color={colors.paused} />
                <StatCard
                  label="Overall Uptime"
                  value={`${summary.overallUptimePercent.toFixed(2)}%`}
                  color={colors.primary}
                />
              </View>
            </>
          ) : null}

          <Text style={styles.sectionTitle}>Endpoints</Text>
        </View>
      }
      renderItem={({ item }) => (
        <EndpointCard
          endpoint={{
            id: item.id,
            name: item.name,
            url: item.url,
            isPaused: item.isPaused,
            isHealthy: item.latestCheck?.isHealthy ?? null,
            responseTimeMs: item.latestCheck?.responseTimeMs,
          }}
          onPress={() => router.push(`/endpoints/${item.id}`)}
        />
      )}
      ItemSeparatorComponent={() => <View style={styles.separator} />}
      ListEmptyComponent={
        <EmptyState
          icon="pulse-outline"
          title="No endpoints yet"
          message="Add an endpoint to start monitoring its health."
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
  heading: {
    fontSize: 26,
    fontWeight: '700',
    color: colors.text,
  },
  statsRow: {
    flexDirection: 'row',
    gap: 10,
  },
  sectionTitle: {
    fontSize: 18,
    fontWeight: '600',
    color: colors.text,
    marginTop: 8,
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
