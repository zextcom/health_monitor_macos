import { StyleSheet, Text, View } from 'react-native';
import { colors } from '../theme/colors';

interface StatCardProps {
  label: string;
  value: string | number;
  color?: string;
}

export function StatCard({ label, value, color = colors.text }: StatCardProps) {
  return (
    <View style={styles.card}>
      {/* One line, shrunk to fit: "100.00%" at 24pt is wider than a third-width card, which pushed the "%" onto a second line. */}
      <Text
        style={[styles.value, { color }]}
        numberOfLines={1}
        adjustsFontSizeToFit
        minimumFontScale={0.6}
      >
        {value}
      </Text>
      <Text style={styles.label}>{label}</Text>
    </View>
  );
}

const styles = StyleSheet.create({
  card: {
    flex: 1,
    minWidth: 100,
    backgroundColor: colors.card,
    borderRadius: 12,
    borderWidth: 1,
    borderColor: colors.border,
    paddingVertical: 16,
    paddingHorizontal: 12,
    alignItems: 'center',
    gap: 4,
  },
  value: {
    fontSize: 24,
    fontWeight: '700',
    // Fill the card's width so the font-size fitting has a bound to shrink to.
    alignSelf: 'stretch',
    textAlign: 'center',
  },
  label: {
    fontSize: 12,
    color: colors.textSecondary,
    textAlign: 'center',
  },
});
