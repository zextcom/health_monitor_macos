import { useCallback, useState } from 'react';
import { FlatList, RefreshControl, StyleSheet, Text, View } from 'react-native';
import { useRouter } from 'expo-router';
import { colors } from '../../src/theme/colors';
import { listEndpoints, type Endpoint } from '../../src/api/endpoints';
import { ApiError } from '../../src/api/client';
import { EndpointCard } from '../../src/components/EndpointCard';
import { EmptyState } from '../../src/components/EmptyState';
import { useRefreshOnFocus } from '../../src/hooks/useRefreshOnFocus';

export default function EndpointsScreen() {
  const router = useRouter();
  const [endpoints, setEndpoints] = useState<Endpoint[]>([]);
  const [isLoading, setIsLoading] = useState(true);
  const [refreshing, setRefreshing] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const fetchEndpoints = useCallback(async () => {
    try {
      setError(null);
      const result = await listEndpoints();
      setEndpoints(result);
    } catch (err) {
      setError(err instanceof ApiError ? err.message : 'Failed to load endpoints');
    } finally {
      setIsLoading(false);
      setRefreshing(false);
    }
  }, []);

  useRefreshOnFocus(fetchEndpoints);

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

  return (
    <FlatList
      style={styles.container}
      contentContainerStyle={styles.content}
      data={endpoints}
      keyExtractor={(item) => item.id}
      refreshControl={<RefreshControl refreshing={refreshing} onRefresh={onRefresh} />}
      ListHeaderComponent={
        <View style={styles.headerSection}>
          <Text style={styles.heading}>Endpoints</Text>
          {error ? (
            <View style={styles.errorBox}>
              <Text style={styles.errorText}>{error}</Text>
            </View>
          ) : null}
        </View>
      }
      renderItem={({ item }) => (
        <EndpointCard
          endpoint={{
            id: item.id,
            name: item.name,
            url: item.url,
            isPaused: item.isPaused,
            isHealthy: null,
          }}
          onPress={() => router.push(`/endpoints/${item.id}`)}
        />
      )}
      ItemSeparatorComponent={() => <View style={styles.separator} />}
      ListEmptyComponent={
        <EmptyState
          icon="link-outline"
          title="No endpoints"
          message="Endpoints you add will show up here."
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
