import { useCallback, useState } from 'react';
import { ActivityIndicator, Pressable, ScrollView, StyleSheet, Text, View } from 'react-native';
import { Stack, useLocalSearchParams } from 'expo-router';
import { colors } from '../../src/theme/colors';
import { ApiError } from '../../src/api/client';
import { getEndpoint, pauseEndpoint, resumeEndpoint, type Endpoint } from '../../src/api/endpoints';
import {
  getCheckHistory,
  getIncidents,
  getUptime,
  type HealthCheckResult,
  type Incident,
  type UptimeResponse,
} from '../../src/api/checks';
import { StatusBadge, statusFromEndpoint } from '../../src/components/StatusBadge';
import { EmptyState } from '../../src/components/EmptyState';
import { useRefreshOnFocus } from '../../src/hooks/useRefreshOnFocus';

export default function EndpointDetailScreen() {
  const { id } = useLocalSearchParams<{ id: string }>();
  const [endpoint, setEndpoint] = useState<Endpoint | null>(null);
  const [history, setHistory] = useState<HealthCheckResult[]>([]);
  const [uptime, setUptime] = useState<UptimeResponse | null>(null);
  const [incidents, setIncidents] = useState<Incident[]>([]);
  const [isLoading, setIsLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [isToggling, setIsToggling] = useState(false);

  const fetchData = useCallback(async () => {
    if (!id) return;
    try {
      setError(null);
      const [endpointResult, historyResult, uptimeResult, incidentsResult] = await Promise.all([
        getEndpoint(id),
        getCheckHistory(id, { limit: 20 }),
        getUptime(id, 7),
        getIncidents(id, 5),
      ]);
      setEndpoint(endpointResult);
      setHistory(historyResult);
      setUptime(uptimeResult);
      setIncidents(incidentsResult);
    } catch (err) {
      setError(err instanceof ApiError ? err.message : 'Failed to load endpoint');
    } finally {
      setIsLoading(false);
    }
  }, [id]);

  useRefreshOnFocus(fetchData);

  const handleToggle = async () => {
    if (!endpoint) return;
    setIsToggling(true);
    try {
      const updated = endpoint.isPaused ? await resumeEndpoint(endpoint.id) : await pauseEndpoint(endpoint.id);
      setEndpoint(updated);
    } catch (err) {
      setError(err instanceof ApiError ? err.message : 'Failed to update endpoint');
    } finally {
      setIsToggling(false);
    }
  };

  if (isLoading) {
    return (
      <View style={styles.centered}>
        <ActivityIndicator size="large" color={colors.primary} />
      </View>
    );
  }

  if (!endpoint) {
    return (
      <View style={styles.container}>
        <Stack.Screen options={{ title: 'Endpoint' }} />
        <EmptyState
          icon="alert-circle-outline"
          title="Endpoint not found"
          message={error ?? undefined}
        />
      </View>
    );
  }

  const latestCheck = history[0] ?? null;
  const status = statusFromEndpoint({
    isPaused: endpoint.isPaused,
    isHealthy: latestCheck?.isHealthy ?? null,
  });
  const activeIncident = incidents.find((incident) => incident.isOngoing) ?? null;

  return (
    <ScrollView style={styles.container} contentContainerStyle={styles.content}>
      <Stack.Screen options={{ title: endpoint.name }} />

      {error ? (
        <View style={styles.errorBox}>
          <Text style={styles.errorText}>{error}</Text>
        </View>
      ) : null}

      <View style={styles.card}>
        <View style={styles.titleRow}>
          <Text style={styles.name}>{endpoint.name}</Text>
          <StatusBadge status={status} />
        </View>
        <Text style={styles.url}>{endpoint.url}</Text>

        <View style={styles.detailGrid}>
          <DetailItem label="Check Type" value={endpoint.checkType.toUpperCase()} />
          <DetailItem label="Interval" value={`${endpoint.checkInterval}s`} />
          <DetailItem label="Expected Status" value={String(endpoint.expectedStatusCode)} />
          <DetailItem label="Group" value={endpoint.groupName ?? '—'} />
        </View>
      </View>

      <View style={styles.card}>
        <Text style={styles.sectionTitle}>Latest Check</Text>
        {latestCheck ? (
          <View style={styles.detailGrid}>
            <DetailItem label="Status Code" value={latestCheck.statusCode?.toString() ?? '—'} />
            <DetailItem
              label="Response Time"
              value={latestCheck.responseTimeMs != null ? `${latestCheck.responseTimeMs} ms` : '—'}
            />
            <DetailItem label="Checked At" value={new Date(latestCheck.timestamp).toLocaleString()} />
            {latestCheck.failureReason ? (
              <DetailItem label="Failure Reason" value={latestCheck.failureReason} />
            ) : null}
          </View>
        ) : (
          <Text style={styles.muted}>No checks recorded yet.</Text>
        )}
      </View>

      {activeIncident ? (
        <View style={[styles.card, styles.incidentCard]}>
          <Text style={styles.sectionTitle}>Active Incident</Text>
          <Text style={styles.incidentReason}>{activeIncident.failureReason ?? 'Unknown failure'}</Text>
          <Text style={styles.muted}>Since {new Date(activeIncident.startedAt).toLocaleString()}</Text>
        </View>
      ) : null}

      <View style={styles.card}>
        <Text style={styles.sectionTitle}>Uptime (7 days)</Text>
        {uptime ? (
          <View style={styles.detailGrid}>
            <DetailItem label="Uptime" value={`${uptime.uptimePercent.toFixed(2)}%`} />
            <DetailItem label="Total Checks" value={String(uptime.totalChecks)} />
            <DetailItem label="Failed Checks" value={String(uptime.downChecks)} />
          </View>
        ) : (
          <Text style={styles.muted}>No uptime data yet.</Text>
        )}
      </View>

      <View style={styles.card}>
        <Text style={styles.sectionTitle}>Recent Checks</Text>
        {history.length === 0 ? (
          <Text style={styles.muted}>No check history yet.</Text>
        ) : (
          history.map((check) => (
            <View key={check.id} style={styles.historyRow}>
              <View style={[styles.historyDot, { backgroundColor: check.isHealthy ? colors.healthy : colors.unhealthy }]} />
              <Text style={styles.historyTime}>{new Date(check.timestamp).toLocaleString()}</Text>
              <Text style={styles.historyMeta}>
                {check.statusCode ?? '—'} · {check.responseTimeMs != null ? `${check.responseTimeMs}ms` : '—'}
              </Text>
            </View>
          ))
        )}
      </View>

      <Pressable
        style={({ pressed }) => [
          styles.toggleButton,
          endpoint.isPaused ? styles.resumeButton : styles.pauseButton,
          pressed && styles.buttonPressed,
        ]}
        onPress={handleToggle}
        disabled={isToggling}
      >
        {isToggling ? (
          <ActivityIndicator color="#fff" />
        ) : (
          <Text style={styles.toggleButtonText}>{endpoint.isPaused ? 'Resume Monitoring' : 'Pause Monitoring'}</Text>
        )}
      </Pressable>
    </ScrollView>
  );
}

function DetailItem({ label, value }: { label: string; value: string }) {
  return (
    <View style={styles.detailItem}>
      <Text style={styles.detailLabel}>{label}</Text>
      <Text style={styles.detailValue}>{value}</Text>
    </View>
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
  card: {
    backgroundColor: colors.card,
    borderRadius: 12,
    borderWidth: 1,
    borderColor: colors.border,
    padding: 16,
    gap: 12,
  },
  titleRow: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    gap: 8,
  },
  name: {
    fontSize: 20,
    fontWeight: '700',
    color: colors.text,
    flexShrink: 1,
  },
  url: {
    fontSize: 14,
    color: colors.textSecondary,
  },
  sectionTitle: {
    fontSize: 15,
    fontWeight: '600',
    color: colors.text,
  },
  detailGrid: {
    flexDirection: 'row',
    flexWrap: 'wrap',
    gap: 16,
  },
  detailItem: {
    minWidth: '40%',
    gap: 2,
  },
  detailLabel: {
    fontSize: 12,
    color: colors.textSecondary,
  },
  detailValue: {
    fontSize: 15,
    fontWeight: '600',
    color: colors.text,
  },
  muted: {
    color: colors.textSecondary,
    fontSize: 14,
  },
  incidentCard: {
    borderColor: colors.unhealthy,
    backgroundColor: `${colors.unhealthy}0d`,
  },
  incidentReason: {
    color: colors.unhealthy,
    fontSize: 14,
    fontWeight: '600',
  },
  historyRow: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 8,
    paddingVertical: 6,
    borderBottomWidth: StyleSheet.hairlineWidth,
    borderBottomColor: colors.border,
  },
  historyDot: {
    width: 8,
    height: 8,
    borderRadius: 4,
  },
  historyTime: {
    flex: 1,
    fontSize: 13,
    color: colors.text,
  },
  historyMeta: {
    fontSize: 12,
    color: colors.textSecondary,
  },
  toggleButton: {
    borderRadius: 10,
    paddingVertical: 14,
    alignItems: 'center',
    justifyContent: 'center',
    marginTop: 4,
    marginBottom: 24,
  },
  pauseButton: {
    backgroundColor: colors.paused,
  },
  resumeButton: {
    backgroundColor: colors.healthy,
  },
  buttonPressed: {
    opacity: 0.8,
  },
  toggleButtonText: {
    color: '#fff',
    fontSize: 16,
    fontWeight: '600',
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
