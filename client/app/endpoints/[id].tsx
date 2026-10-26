import { useCallback, useRef, useState } from 'react';
import { ActivityIndicator, Alert, Platform, Pressable, ScrollView, StyleSheet, Text, View } from 'react-native';
import { Stack, useLocalSearchParams, useRouter } from 'expo-router';
import { Ionicons } from '@expo/vector-icons';
import { colors } from '../../src/theme/colors';
import { ApiError } from '../../src/api/client';
import {
  deleteEndpoint,
  getEndpoint,
  getEndpointHealthDetails,
  getEndpointVersions,
  pauseEndpoint,
  resumeEndpoint,
  type Endpoint,
  type HealthDetailsResponse,
  type VersionHistoryResponse,
} from '../../src/api/endpoints';
import {
  getCheckHistory,
  getIncidents,
  getUptime,
  type HealthCheckResult,
  type Incident,
  type UptimeResponse,
} from '../../src/api/checks';
import { StateMarker, StatusBadge } from '../../src/components/StatusBadge';
import { EmptyState } from '../../src/components/EmptyState';
import { useRefreshOnFocus } from '../../src/hooks/useRefreshOnFocus';
import { useSSE } from '../../src/hooks/useSSE';
import { deleteConfirmation, isAlreadyDeleted } from '../../src/logic/deleteEndpoint';
import { checkState, deriveStatus, stateOfHealthStatus } from '../../src/logic/status';
import {
  formatDateTime,
  formatSeenRange,
  formatVersion,
  healthStatusLabel,
  shouldShowHealthReport,
  shouldShowVersion,
  sortVersionHistory,
  versionSourceLabel,
  versionSourceOf,
  versionStatusText,
} from '../../src/logic/format';

/** `Alert.alert` has no buttons on react-native-web, so the web build falls back to `window.confirm`. */
function confirmDelete(name: string): Promise<boolean> {
  const { title, message } = deleteConfirmation(name);
  if (Platform.OS === 'web') {
    return Promise.resolve(window.confirm(`${title}\n\n${message}`));
  }
  return new Promise((resolve) => {
    Alert.alert(
      title,
      message,
      [
        { text: 'Cancel', style: 'cancel', onPress: () => resolve(false) },
        { text: 'Delete', style: 'destructive', onPress: () => resolve(true) },
      ],
      { cancelable: true, onDismiss: () => resolve(false) },
    );
  });
}

export default function EndpointDetailScreen() {
  const { id } = useLocalSearchParams<{ id: string }>();
  const router = useRouter();
  const [endpoint, setEndpoint] = useState<Endpoint | null>(null);
  const [history, setHistory] = useState<HealthCheckResult[]>([]);
  const [uptime, setUptime] = useState<UptimeResponse | null>(null);
  const [incidents, setIncidents] = useState<Incident[]>([]);
  const [isLoading, setIsLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [isToggling, setIsToggling] = useState(false);
  const [isDeleting, setIsDeleting] = useState(false);
  // Optional extras: an older backend without these routes still shows the rest of the screen.
  const [versions, setVersions] = useState<VersionHistoryResponse | null>(null);
  const [healthDetails, setHealthDetails] = useState<HealthDetailsResponse | null>(null);

  const fetchData = useCallback(async () => {
    if (!id) return;
    try {
      setError(null);
      const [endpointResult, historyResult, uptimeResult, incidentsResult, versionsResult, detailsResult] =
        await Promise.all([
          getEndpoint(id),
          getCheckHistory(id, { limit: 20 }),
          getUptime(id, 7),
          getIncidents(id, 5),
          getEndpointVersions(id).catch(() => null),
          getEndpointHealthDetails(id).catch(() => null),
        ]);
      setEndpoint(endpointResult);
      setHistory(historyResult);
      setUptime(uptimeResult);
      setIncidents(incidentsResult);
      setVersions(versionsResult);
      setHealthDetails(detailsResult);
    } catch (err) {
      setError(err instanceof ApiError ? err.message : 'Failed to load endpoint');
    } finally {
      setIsLoading(false);
    }
  }, [id]);

  useRefreshOnFocus(fetchData);

  // Live updates (web): a new result for this endpoint refetches the screen, coalescing bursts.
  const refetchTimer = useRef<ReturnType<typeof setTimeout> | null>(null);
  useSSE(
    useCallback(
      (event) => {
        if (event.endpointId !== id || refetchTimer.current) return;
        refetchTimer.current = setTimeout(() => {
          refetchTimer.current = null;
          fetchData();
        }, 1_000);
      },
      [id, fetchData],
    ),
  );

  const openEditForm = useCallback(() => {
    if (id) router.push({ pathname: '/endpoint-form', params: { id } });
  }, [id, router]);

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

  const handleDelete = async () => {
    if (!endpoint || isDeleting) return;
    if (!(await confirmDelete(endpoint.name))) return;

    setIsDeleting(true);
    try {
      await deleteEndpoint(endpoint.id);
    } catch (err) {
      if (!(err instanceof ApiError && isAlreadyDeleted(err.status))) {
        setError(err instanceof ApiError ? err.message : 'Failed to delete endpoint');
        setIsDeleting(false);
        return;
      }
    }
    // The list refetches when it regains focus, so it drops the deleted endpoint by itself.
    if (router.canGoBack()) {
      router.back();
    } else {
      router.replace('/(tabs)/endpoints');
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
  const status = deriveStatus({
    isPaused: endpoint.isPaused,
    isHealthy: latestCheck?.isHealthy ?? null,
    healthStatus: latestCheck?.healthStatus ?? null,
  });
  const activeIncident = incidents.find((incident) => incident.isOngoing) ?? null;
  const versionSource = versionSourceOf(endpoint);

  return (
    <ScrollView style={styles.container} contentContainerStyle={styles.content}>
      <Stack.Screen
        options={{
          title: endpoint.name,
          headerRight: () => (
            <Pressable
              onPress={openEditForm}
              hitSlop={8}
              style={({ pressed }) => [styles.headerButton, pressed && styles.buttonPressed]}
              accessibilityRole="button"
              accessibilityLabel="Edit endpoint"
            >
              <Text style={styles.headerButtonText}>Edit</Text>
            </Pressable>
          ),
        }}
      />

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
          {endpoint.checkType === 'http' ? (
            endpoint.healthStandard ? (
              <DetailItem label="Evaluation" value="Zext Health Standard" />
            ) : (
              <DetailItem label="Expected Status" value={String(endpoint.expectedStatusCode)} />
            )
          ) : null}
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
              <DetailItem
                label={status === 'degraded' ? 'Degraded Reason' : 'Failure Reason'}
                value={latestCheck.failureReason}
              />
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

      {shouldShowVersion(versions, versionSource) ? (
        <VersionSection endpoint={endpoint} versions={versions} />
      ) : null}

      {shouldShowHealthReport(healthDetails, endpoint) ? <ReportedHealthSection details={healthDetails} /> : null}

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
              <StateMarker state={checkState(check)} />
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
        disabled={isToggling || isDeleting}
      >
        {isToggling ? (
          <ActivityIndicator color="#fff" />
        ) : (
          <Text style={styles.toggleButtonText}>{endpoint.isPaused ? 'Resume Monitoring' : 'Pause Monitoring'}</Text>
        )}
      </Pressable>

      <Pressable
        style={({ pressed }) => [styles.deleteButton, pressed && styles.buttonPressed]}
        onPress={handleDelete}
        disabled={isToggling || isDeleting}
        accessibilityRole="button"
        accessibilityLabel="Delete endpoint"
      >
        {isDeleting ? (
          <ActivityIndicator color={colors.unhealthy} />
        ) : (
          <Text style={styles.deleteButtonText}>Delete Endpoint</Text>
        )}
      </Pressable>
    </ScrollView>
  );
}

function VersionSection({ endpoint, versions }: { endpoint: Endpoint; versions: VersionHistoryResponse | null }) {
  const source = versionSourceOf(endpoint);
  const current = versions?.current ?? null;
  const isEnabled = source === 'healthStandard' || endpoint.versionCheck?.isEnabled === true;
  const state = versionStatusText(current, { source, isEnabled });
  const history = sortVersionHistory(versions?.history ?? []);
  const toneColor =
    state.tone === 'failing' ? colors.degraded : state.tone === 'ok' ? colors.healthy : colors.textSecondary;

  return (
    <View style={[styles.card, state.tone === 'failing' && styles.versionFailingCard]}>
      <View style={styles.titleRow}>
        <Text style={styles.sectionTitle}>Version</Text>
        {source ? <Text style={styles.muted}>{versionSourceLabel(source)}</Text> : null}
      </View>
      <View style={styles.detailGrid}>
        <DetailItem label="Current" value={formatVersion(current?.version)} />
        <View style={styles.detailItem}>
          <Text style={styles.detailLabel}>State</Text>
          <View style={styles.inlineRow}>
            {state.tone === 'failing' ? <Ionicons name="warning" size={14} color={toneColor} /> : null}
            <Text style={[styles.detailValue, { color: toneColor }]}>{state.label}</Text>
          </View>
        </View>
        <DetailItem label="Last Checked" value={formatDateTime(current?.lastCheckedAt)} />
      </View>
      {state.detail ? <Text style={[styles.reasonText, { color: colors.degraded }]}>{state.detail}</Text> : null}

      <Text style={styles.subsectionTitle}>History (newest first)</Text>
      {history.length === 0 ? (
        <Text style={styles.muted}>No versions recorded yet.</Text>
      ) : (
        history.map((entry, index) => (
          <View key={`${entry.value}-${entry.firstSeenAt}`} style={styles.historyRow}>
            <Text style={[styles.versionValue, index === 0 && styles.versionValueCurrent]}>
              {formatVersion(entry.value)}
            </Text>
            <Text style={styles.historyMeta}>{formatSeenRange(entry)}</Text>
          </View>
        ))
      )}
    </View>
  );
}

function ReportedHealthSection({ details }: { details: HealthDetailsResponse | null }) {
  const latest = details?.latest ?? null;
  const overall = latest ? stateOfHealthStatus(latest.status) : null;

  return (
    <View style={styles.card}>
      <View style={styles.titleRow}>
        <Text style={styles.sectionTitle}>Reported health</Text>
        {latest && overall ? (
          <View style={styles.inlineRow}>
            <StateMarker state={overall} />
            <Text style={[styles.detailValue, { color: colors[overall] }]}>{healthStatusLabel(latest.status)}</Text>
          </View>
        ) : null}
      </View>
      {!latest ? (
        <Text style={styles.muted}>No health-standard response read yet.</Text>
      ) : (
        <>
          {latest.output ? <Text style={styles.reasonText}>{latest.output}</Text> : null}
          <Text style={styles.muted}>Reported {formatDateTime(latest.checkedAt)}</Text>
        </>
      )}
    </View>
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
  headerButton: {
    paddingHorizontal: 12,
    paddingVertical: 6,
  },
  headerButtonText: {
    color: colors.primary,
    fontSize: 16,
    fontWeight: '600',
  },
  inlineRow: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 6,
  },
  subsectionTitle: {
    fontSize: 13,
    fontWeight: '600',
    color: colors.textSecondary,
    marginTop: 4,
  },
  reasonText: {
    fontSize: 14,
    color: colors.text,
  },
  versionFailingCard: {
    borderColor: colors.degraded,
  },
  versionValue: {
    flex: 1,
    fontSize: 14,
    color: colors.text,
  },
  versionValueCurrent: {
    fontWeight: '700',
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
  },
  deleteButton: {
    borderWidth: 1,
    borderColor: colors.unhealthy,
    borderRadius: 10,
    paddingVertical: 14,
    alignItems: 'center',
    justifyContent: 'center',
    marginBottom: 24,
  },
  deleteButtonText: {
    color: colors.unhealthy,
    fontSize: 16,
    fontWeight: '600',
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
