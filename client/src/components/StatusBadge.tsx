import { StyleSheet, Text, View } from 'react-native';
import { Ionicons } from '@expo/vector-icons';
import type { ComponentProps } from 'react';
import { colors } from '../theme/colors';
import { deriveStatus, type CheckState, type Status, type StatusInput } from '../logic/status';

export type { Status } from '../logic/status';

type IconName = ComponentProps<typeof Ionicons>['name'];

interface StatusBadgeProps {
  status: Status;
}

const LABELS: Record<Status, string> = {
  healthy: 'Healthy',
  degraded: 'Degraded',
  unhealthy: 'Unhealthy',
  paused: 'Paused',
  unknown: 'Unknown',
};

// Each state has its own icon shape, so the badge doesn't rely on color alone (same shapes as
// the macOS app: check circle / warning triangle / exclamation circle).
const ICONS: Record<Status, IconName> = {
  healthy: 'checkmark-circle',
  degraded: 'warning',
  unhealthy: 'alert-circle',
  paused: 'pause-circle',
  unknown: 'help-circle',
};

export function StatusBadge({ status }: StatusBadgeProps) {
  const color = colors[status];

  return (
    <View
      style={[styles.badge, { backgroundColor: `${color}1a`, borderColor: color }]}
      accessibilityRole="text"
      accessibilityLabel={`Status: ${LABELS[status]}`}
    >
      <Ionicons name={ICONS[status]} size={13} color={color} />
      <Text style={[styles.label, { color }]}>{LABELS[status]}</Text>
    </View>
  );
}

// History markers: circle (healthy), triangle (degraded), square (down), like the macOS detail
// chart points.
const MARKER_ICONS: Record<CheckState, IconName> = {
  healthy: 'ellipse',
  degraded: 'triangle',
  unhealthy: 'square',
};

const MARKER_LABELS: Record<CheckState, string> = {
  healthy: 'Healthy',
  degraded: 'Degraded',
  unhealthy: 'Down',
};

export function StateMarker({ state, size = 10 }: { state: CheckState; size?: number }) {
  return (
    <Ionicons
      name={MARKER_ICONS[state]}
      size={size}
      color={colors[state]}
      accessibilityLabel={MARKER_LABELS[state]}
    />
  );
}

/** Kept for existing callers; see `deriveStatus` for the rules. */
export function statusFromEndpoint(input: StatusInput): Status {
  return deriveStatus(input);
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
    gap: 5,
  },
  label: {
    fontSize: 12,
    fontWeight: '600',
  },
});
