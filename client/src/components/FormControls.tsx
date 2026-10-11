import type { ReactNode } from 'react';
import { Pressable, StyleSheet, Switch, Text, TextInput, View, type TextInputProps } from 'react-native';
import { Ionicons } from '@expo/vector-icons';
import { colors } from '../theme/colors';
import type { MatchMode } from '../api/endpoints';
import { newAssertionDraft, type AssertionDraft } from '../logic/endpointForm';

export function FormSection({ title, children }: { title?: string; children: ReactNode }) {
  return (
    <View style={styles.section}>
      {title ? <Text style={styles.sectionTitle}>{title}</Text> : null}
      {children}
    </View>
  );
}

interface FormFieldProps extends Omit<TextInputProps, 'style'> {
  label: string;
  hint?: string;
  error?: string;
}

export function FormField({ label, hint, error, ...inputProps }: FormFieldProps) {
  return (
    <View style={styles.field}>
      <Text style={styles.label}>{label}</Text>
      <TextInput
        placeholderTextColor={colors.textSecondary}
        accessibilityLabel={label}
        {...inputProps}
        style={[styles.input, error ? styles.inputError : null]}
      />
      {error ? <FieldError message={error} /> : hint ? <Text style={styles.hint}>{hint}</Text> : null}
    </View>
  );
}

export function FieldError({ message }: { message: string }) {
  return (
    <View style={styles.errorRow} accessibilityLiveRegion="polite">
      <Ionicons name="alert-circle" size={14} color={colors.unhealthy} />
      <Text style={styles.errorText}>{message}</Text>
    </View>
  );
}

export function Hint({ children }: { children: ReactNode }) {
  return <Text style={styles.hint}>{children}</Text>;
}

interface SegmentedControlProps<T extends string> {
  label?: string;
  options: ReadonlyArray<{ value: T; label: string }>;
  value: T;
  onChange: (value: T) => void;
  compact?: boolean;
}

export function SegmentedControl<T extends string>({ label, options, value, onChange, compact }: SegmentedControlProps<T>) {
  return (
    <View style={styles.field}>
      {label ? <Text style={styles.label}>{label}</Text> : null}
      <View style={styles.segmented} accessibilityRole="radiogroup" accessibilityLabel={label}>
        {options.map((option) => {
          const selected = option.value === value;
          return (
            <Pressable
              key={option.value}
              onPress={() => onChange(option.value)}
              style={[styles.segment, compact && styles.segmentCompact, selected && styles.segmentSelected]}
              accessibilityRole="radio"
              accessibilityState={{ selected }}
              accessibilityLabel={option.label}
            >
              <Text
                style={[styles.segmentText, compact && styles.segmentTextCompact, selected && styles.segmentTextSelected]}
                numberOfLines={1}
              >
                {option.label}
              </Text>
            </Pressable>
          );
        })}
      </View>
    </View>
  );
}

interface ToggleRowProps {
  label: string;
  description?: string;
  value: boolean;
  onValueChange: (value: boolean) => void;
}

export function ToggleRow({ label, description, value, onValueChange }: ToggleRowProps) {
  return (
    <View style={styles.toggleRow}>
      <View style={styles.toggleText}>
        <Text style={styles.toggleLabel}>{label}</Text>
        {description ? <Text style={styles.hint}>{description}</Text> : null}
      </View>
      <Switch
        value={value}
        onValueChange={onValueChange}
        trackColor={{ false: colors.border, true: colors.primary }}
        accessibilityLabel={label}
      />
    </View>
  );
}

const MATCH_MODES: ReadonlyArray<{ value: MatchMode; label: string }> = [
  { value: 'exact', label: 'Exact' },
  { value: 'contains', label: 'Contains' },
  { value: 'regex', label: 'Regex' },
];

interface AssertionListEditorProps {
  rows: AssertionDraft[];
  onChange: (rows: AssertionDraft[]) => void;
  error?: string;
  /** Prefix for accessibility labels, e.g. "Version assertion". */
  itemLabel?: string;
}

export function AssertionListEditor({ rows, onChange, error, itemLabel = 'Assertion' }: AssertionListEditorProps) {
  const updateRow = (key: string, patch: Partial<AssertionDraft>) =>
    onChange(rows.map((row) => (row.key === key ? { ...row, ...patch } : row)));

  return (
    <View style={styles.assertions}>
      {rows.map((row, index) => (
        <View key={row.key} style={styles.assertionRow}>
          <View style={styles.assertionHeader}>
            <Text style={styles.assertionTitle}>
              {itemLabel} {index + 1}
            </Text>
            <Pressable
              onPress={() => onChange(rows.filter((other) => other.key !== row.key))}
              hitSlop={8}
              accessibilityRole="button"
              accessibilityLabel={`Remove ${itemLabel.toLowerCase()} ${index + 1}`}
            >
              <Ionicons name="remove-circle" size={22} color={colors.textSecondary} />
            </Pressable>
          </View>
          <TextInput
            value={row.path}
            onChangeText={(path) => updateRow(row.key, { path })}
            placeholder="JSON field, e.g. data.status"
            placeholderTextColor={colors.textSecondary}
            autoCapitalize="none"
            autoCorrect={false}
            style={styles.input}
            accessibilityLabel={`${itemLabel} ${index + 1} field path`}
          />
          <TextInput
            value={row.expectedValue}
            onChangeText={(expectedValue) => updateRow(row.key, { expectedValue })}
            placeholder="Expected value, e.g. healthy"
            placeholderTextColor={colors.textSecondary}
            autoCapitalize="none"
            autoCorrect={false}
            style={styles.input}
            accessibilityLabel={`${itemLabel} ${index + 1} expected value`}
          />
          <SegmentedControl
            options={MATCH_MODES}
            value={row.matchMode}
            onChange={(matchMode) => updateRow(row.key, { matchMode })}
            compact
          />
        </View>
      ))}
      {error ? <FieldError message={error} /> : null}
      <Pressable
        onPress={() => onChange([...rows, newAssertionDraft()])}
        style={({ pressed }) => [styles.addRow, pressed && styles.pressed]}
        accessibilityRole="button"
        accessibilityLabel={`Add ${itemLabel.toLowerCase()}`}
      >
        <Ionicons name="add-circle-outline" size={18} color={colors.primary} />
        <Text style={styles.addRowText}>Add {itemLabel.toLowerCase()}</Text>
      </Pressable>
    </View>
  );
}

const styles = StyleSheet.create({
  section: {
    backgroundColor: colors.card,
    borderRadius: 12,
    borderWidth: 1,
    borderColor: colors.border,
    padding: 16,
    gap: 14,
  },
  sectionTitle: {
    fontSize: 15,
    fontWeight: '600',
    color: colors.text,
  },
  field: {
    gap: 6,
  },
  label: {
    fontSize: 13,
    fontWeight: '600',
    color: colors.text,
  },
  input: {
    borderWidth: 1,
    borderColor: colors.border,
    borderRadius: 8,
    paddingHorizontal: 12,
    paddingVertical: 10,
    fontSize: 15,
    color: colors.text,
    backgroundColor: colors.background,
  },
  inputError: {
    borderColor: colors.unhealthy,
  },
  hint: {
    fontSize: 12,
    color: colors.textSecondary,
  },
  errorRow: {
    flexDirection: 'row',
    alignItems: 'flex-start',
    gap: 4,
  },
  errorText: {
    flex: 1,
    fontSize: 12,
    color: colors.unhealthy,
  },
  segmented: {
    flexDirection: 'row',
    borderWidth: 1,
    borderColor: colors.border,
    borderRadius: 8,
    overflow: 'hidden',
  },
  segment: {
    flex: 1,
    alignItems: 'center',
    paddingVertical: 9,
    paddingHorizontal: 4,
    backgroundColor: colors.background,
  },
  segmentCompact: {
    paddingVertical: 6,
  },
  segmentSelected: {
    backgroundColor: colors.primary,
  },
  segmentText: {
    fontSize: 14,
    color: colors.text,
    fontWeight: '500',
  },
  segmentTextCompact: {
    fontSize: 13,
  },
  segmentTextSelected: {
    color: '#fff',
    fontWeight: '600',
  },
  toggleRow: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 12,
  },
  toggleText: {
    flex: 1,
    gap: 2,
  },
  toggleLabel: {
    fontSize: 15,
    fontWeight: '600',
    color: colors.text,
  },
  assertions: {
    gap: 10,
  },
  assertionRow: {
    gap: 8,
    padding: 12,
    borderRadius: 10,
    borderWidth: 1,
    borderColor: colors.border,
  },
  assertionHeader: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
  },
  assertionTitle: {
    fontSize: 13,
    fontWeight: '600',
    color: colors.textSecondary,
  },
  addRow: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 6,
    alignSelf: 'flex-start',
    paddingVertical: 4,
  },
  addRowText: {
    color: colors.primary,
    fontSize: 14,
    fontWeight: '600',
  },
  pressed: {
    opacity: 0.7,
  },
});
