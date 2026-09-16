import { useCallback, useEffect, useState } from 'react';
import Constants from 'expo-constants';
import { ActivityIndicator, Pressable, StyleSheet, Switch, Text, View } from 'react-native';
import { colors } from '../../src/theme/colors';
import { useAuthStore } from '../../src/stores/auth';
import {
  getNotificationPreferences,
  updateNotificationPreferences,
  type NotificationPreferences,
} from '../../src/api/notifications';

export default function SettingsScreen() {
  const { user, logout, isLoading: authLoading } = useAuthStore();
  const [preferences, setPreferences] = useState<NotificationPreferences | null>(null);
  const [prefsLoading, setPrefsLoading] = useState(true);
  const [savingKey, setSavingKey] = useState<'notifyOnDown' | 'notifyOnRecovery' | null>(null);

  const fetchPreferences = useCallback(async () => {
    try {
      const result = await getNotificationPreferences();
      setPreferences(result);
    } catch {
      // Non-critical — leave preferences unset if this fails.
    } finally {
      setPrefsLoading(false);
    }
  }, []);

  useEffect(() => {
    fetchPreferences();
  }, [fetchPreferences]);

  const togglePreference = async (key: 'notifyOnDown' | 'notifyOnRecovery') => {
    if (!preferences) return;
    const nextValue = !preferences[key];
    setSavingKey(key);
    setPreferences({ ...preferences, [key]: nextValue });
    try {
      const updated = await updateNotificationPreferences({ [key]: nextValue });
      setPreferences(updated);
    } catch {
      // Revert on failure.
      setPreferences(preferences);
    } finally {
      setSavingKey(null);
    }
  };

  const appVersion = Constants.expoConfig?.version ?? '1.0.0';

  return (
    <View style={styles.container}>
      <Text style={styles.heading}>Settings</Text>

      <View style={styles.section}>
        <Text style={styles.sectionTitle}>Account</Text>
        <View style={styles.card}>
          <Text style={styles.userName}>{user?.name ?? 'Unknown user'}</Text>
          <Text style={styles.userEmail}>{user?.email ?? ''}</Text>
          {user?.role ? <Text style={styles.userRole}>{user.role.toUpperCase()}</Text> : null}
        </View>
      </View>

      <View style={styles.section}>
        <Text style={styles.sectionTitle}>Notifications</Text>
        <View style={styles.card}>
          {prefsLoading ? (
            <ActivityIndicator color={colors.primary} />
          ) : (
            <>
              <View style={styles.row}>
                <Text style={styles.rowLabel}>Notify on down</Text>
                <Switch
                  value={preferences?.notifyOnDown ?? false}
                  onValueChange={() => togglePreference('notifyOnDown')}
                  disabled={savingKey !== null || !preferences}
                />
              </View>
              <View style={styles.divider} />
              <View style={styles.row}>
                <Text style={styles.rowLabel}>Notify on recovery</Text>
                <Switch
                  value={preferences?.notifyOnRecovery ?? false}
                  onValueChange={() => togglePreference('notifyOnRecovery')}
                  disabled={savingKey !== null || !preferences}
                />
              </View>
            </>
          )}
        </View>
      </View>

      <Pressable
        style={({ pressed }) => [styles.logoutButton, pressed && styles.logoutButtonPressed]}
        onPress={() => logout()}
        disabled={authLoading}
      >
        {authLoading ? (
          <ActivityIndicator color={colors.unhealthy} />
        ) : (
          <Text style={styles.logoutText}>Log Out</Text>
        )}
      </Pressable>

      <Text style={styles.version}>Health Monitor v{appVersion}</Text>
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: colors.background,
    padding: 16,
    gap: 20,
  },
  heading: {
    fontSize: 26,
    fontWeight: '700',
    color: colors.text,
  },
  section: {
    gap: 8,
  },
  sectionTitle: {
    fontSize: 14,
    fontWeight: '600',
    color: colors.textSecondary,
    textTransform: 'uppercase',
  },
  card: {
    backgroundColor: colors.card,
    borderRadius: 12,
    borderWidth: 1,
    borderColor: colors.border,
    padding: 16,
    gap: 4,
  },
  userName: {
    fontSize: 17,
    fontWeight: '600',
    color: colors.text,
  },
  userEmail: {
    fontSize: 14,
    color: colors.textSecondary,
  },
  userRole: {
    marginTop: 4,
    fontSize: 11,
    fontWeight: '700',
    color: colors.primary,
    letterSpacing: 0.5,
  },
  row: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    paddingVertical: 8,
  },
  rowLabel: {
    fontSize: 15,
    color: colors.text,
  },
  divider: {
    height: 1,
    backgroundColor: colors.border,
  },
  logoutButton: {
    marginTop: 8,
    borderWidth: 1,
    borderColor: colors.unhealthy,
    borderRadius: 10,
    paddingVertical: 14,
    alignItems: 'center',
    justifyContent: 'center',
  },
  logoutButtonPressed: {
    opacity: 0.7,
  },
  logoutText: {
    color: colors.unhealthy,
    fontSize: 16,
    fontWeight: '600',
  },
  version: {
    textAlign: 'center',
    color: colors.textSecondary,
    fontSize: 12,
    marginTop: 'auto',
    paddingBottom: 8,
  },
});
