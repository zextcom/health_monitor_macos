import { useCallback, useEffect, useState } from 'react';
import {
  ActivityIndicator,
  KeyboardAvoidingView,
  Platform,
  Pressable,
  ScrollView,
  StyleSheet,
  Text,
  View,
} from 'react-native';
import { Stack, useLocalSearchParams, useRouter } from 'expo-router';
import { useHeaderHeight } from 'expo-router/react-navigation';
import { Ionicons } from '@expo/vector-icons';
import { colors } from '../src/theme/colors';
import { ApiError } from '../src/api/client';
import {
  createEndpoint,
  getEndpoint,
  updateEndpoint,
  type AuthType,
  type CheckType,
  type Endpoint,
} from '../src/api/endpoints';
import {
  ADVANCED_FIELDS,
  DEFAULTS,
  LIMITS,
  canKeepSecret,
  describeApiError,
  emptyFormState,
  formStateFromEndpoint,
  isEmptyUpdate,
  secretLabel,
  shouldExpandAdvanced,
  showsExpectedStatusCode,
  showsHttpOnlyFields,
  validateEndpointForm,
  type EndpointFormState,
  type FormErrors,
  type FormField as FormFieldKey,
  type VersionDraft,
} from '../src/logic/endpointForm';
import {
  AssertionListEditor,
  FieldError,
  FormField,
  FormSection,
  Hint,
  SegmentedControl,
  ToggleRow,
} from '../src/components/FormControls';
import { EmptyState } from '../src/components/EmptyState';

const CHECK_TYPES: ReadonlyArray<{ value: CheckType; label: string }> = [
  { value: 'http', label: 'HTTP' },
  { value: 'tcp', label: 'TCP' },
];

const AUTH_TYPES: ReadonlyArray<{ value: AuthType; label: string }> = [
  { value: 'none', label: 'None' },
  { value: 'bearer_token', label: 'Bearer' },
  { value: 'basic_auth', label: 'Basic' },
  { value: 'custom_header', label: 'Header' },
];

/** Shared by both secret inputs: never autofilled with the user's saved passwords. */
const SECRET_INPUT_PROPS = {
  secureTextEntry: true,
  autoCapitalize: 'none',
  autoCorrect: false,
  autoComplete: 'off',
  textContentType: 'none',
} as const;

const PLAIN_INPUT_PROPS = {
  autoCapitalize: 'none',
  autoCorrect: false,
} as const;

/**
 * Add (no `id` param) or edit (`?id=<endpoint id>`) an endpoint. Presented modally from the
 * Endpoints tab's Add button and the detail screen's Edit button. All validation and payload
 * building lives in src/logic/endpointForm.ts.
 */
export default function EndpointFormScreen() {
  const { id } = useLocalSearchParams<{ id?: string }>();
  const router = useRouter();
  const headerHeight = useHeaderHeight();
  const isEdit = typeof id === 'string' && id.length > 0;

  const [original, setOriginal] = useState<Endpoint | null>(null);
  const [state, setState] = useState<EndpointFormState>(emptyFormState);
  const [isLoading, setIsLoading] = useState(isEdit);
  const [loadError, setLoadError] = useState<string | null>(null);
  const [errors, setErrors] = useState<FormErrors>({});
  const [submitErrors, setSubmitErrors] = useState<string[]>([]);
  const [isSaving, setIsSaving] = useState(false);
  const [isAdvancedExpanded, setIsAdvancedExpanded] = useState(false);

  useEffect(() => {
    if (!isEdit) return;
    let cancelled = false;
    (async () => {
      try {
        const endpoint = await getEndpoint(id);
        if (cancelled) return;
        setOriginal(endpoint);
        setState(formStateFromEndpoint(endpoint));
        setIsAdvancedExpanded(shouldExpandAdvanced(endpoint));
      } catch (err) {
        if (!cancelled) setLoadError(err instanceof ApiError ? err.message : 'Failed to load endpoint');
      } finally {
        if (!cancelled) setIsLoading(false);
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [id, isEdit]);

  /** Applies a change and clears the errors of the fields it touches. */
  const change = useCallback((patch: Partial<EndpointFormState>, fields: FormFieldKey[] = []) => {
    setState((current) => ({ ...current, ...patch }));
    if (fields.length > 0) {
      setErrors((current) => {
        const next = { ...current };
        for (const field of fields) delete next[field];
        return next;
      });
    }
  }, []);

  const changeVersion = useCallback(
    (patch: Partial<VersionDraft>, fields: FormFieldKey[] = []) => {
      setState((current) => ({ ...current, version: { ...current.version, ...patch } }));
      if (fields.length > 0) {
        setErrors((current) => {
          const next = { ...current };
          for (const field of fields) delete next[field];
          return next;
        });
      }
    },
    [],
  );

  const close = useCallback(
    (savedId?: string) => {
      if (savedId && !isEdit) {
        // New endpoint: replace the form with its detail screen.
        router.replace(`/endpoints/${savedId}`);
        return;
      }
      if (router.canGoBack()) {
        router.back();
      } else if (isEdit) {
        router.replace(`/endpoints/${id}`);
      } else {
        router.replace('/(tabs)/endpoints');
      }
    },
    [id, isEdit, router],
  );

  const save = useCallback(async () => {
    if (isSaving) return;
    setSubmitErrors([]);
    const result = validateEndpointForm(state, original);
    if (!result.ok) {
      setErrors(result.errors);
      if (Object.keys(result.errors).some((field) => ADVANCED_FIELDS.includes(field as FormFieldKey))) {
        setIsAdvancedExpanded(true);
      }
      return;
    }
    setErrors({});

    if (result.mode === 'update' && isEmptyUpdate(result.payload)) {
      close();
      return;
    }

    setIsSaving(true);
    try {
      if (result.mode === 'create') {
        const created = await createEndpoint(result.payload);
        close(created.id);
      } else if (original) {
        await updateEndpoint(original.id, result.payload);
        close(original.id);
      }
    } catch (err) {
      if (err instanceof ApiError) {
        setSubmitErrors(describeApiError(err.details, err.message));
      } else {
        setSubmitErrors(['Could not reach the server. Check your connection and try again.']);
      }
    } finally {
      setIsSaving(false);
    }
  }, [close, isSaving, original, state]);

  const title = isEdit ? 'Edit Endpoint' : 'Add Endpoint';
  const screenOptions = (
    <Stack.Screen
      options={{
        title,
        headerLeft: () => (
          <Pressable
            onPress={() => close()}
            hitSlop={8}
            style={styles.headerButton}
            accessibilityRole="button"
            accessibilityLabel="Cancel"
          >
            <Text style={styles.headerButtonText}>Cancel</Text>
          </Pressable>
        ),
        headerRight: () =>
          isLoading || loadError ? null : (
            <Pressable
              onPress={save}
              disabled={isSaving}
              hitSlop={8}
              style={styles.headerButton}
              accessibilityRole="button"
              accessibilityLabel="Save"
            >
              <Text style={[styles.headerButtonText, styles.headerButtonPrimary]}>Save</Text>
            </Pressable>
          ),
      }}
    />
  );

  if (isLoading) {
    return (
      <View style={styles.centered}>
        {screenOptions}
        <ActivityIndicator size="large" color={colors.primary} />
      </View>
    );
  }

  if (loadError) {
    return (
      <View style={styles.container}>
        {screenOptions}
        <EmptyState icon="alert-circle-outline" title="Endpoint not found" message={loadError} />
      </View>
    );
  }

  const isHttp = showsHttpOnlyFields(state);
  const secretKeep = canKeepSecret(original?.authType, state.authType);
  const versionSecretKeep = canKeepSecret(original?.versionCheck?.authType, state.version.authType);
  const errorCount = Object.keys(errors).length;

  return (
    <KeyboardAvoidingView
      style={styles.container}
      behavior={Platform.OS === 'ios' ? 'padding' : undefined}
      keyboardVerticalOffset={headerHeight}
    >
      {screenOptions}
      <ScrollView contentContainerStyle={styles.content} keyboardShouldPersistTaps="handled">
        {submitErrors.length > 0 ? (
          <View style={styles.errorBox} accessibilityLiveRegion="polite">
            <Text style={styles.errorTitle}>The server rejected the endpoint</Text>
            {submitErrors.map((line) => (
              <Text key={line} style={styles.errorText}>
                {line}
              </Text>
            ))}
          </View>
        ) : null}

        <FormSection title="Details">
          <FormField
            label="Name"
            value={state.name}
            onChangeText={(name) => change({ name }, ['name'])}
            placeholder="e.g. Payments API"
            maxLength={LIMITS.nameMaxLength}
            error={errors.name}
          />
          <SegmentedControl
            label="Check type"
            options={CHECK_TYPES}
            value={state.checkType}
            onChange={(checkType) => change({ checkType }, ['url'])}
          />
          <FormField
            label={isHttp ? 'URL' : 'Host and port'}
            value={state.url}
            onChangeText={(url) => change({ url }, ['url'])}
            placeholder={isHttp ? 'https://api.example.com/health' : 'tcp://db.example.com:5432'}
            inputMode="url"
            {...PLAIN_INPUT_PROPS}
            hint={isHttp ? undefined : 'TCP checks only open a connection, as tcp://host:port.'}
            error={errors.url}
          />
          {isHttp ? (
            <ToggleRow
              label="Uses Zext Health Standard"
              description="Reads pass / warn / fail from the JSON status (HTTP 200 or 503) instead of a status code; warn shows as degraded, and version and components come from the same response."
              value={state.healthStandard}
              onValueChange={(healthStandard) => change({ healthStandard }, ['expectedStatusCode'])}
            />
          ) : null}
          {showsExpectedStatusCode(state) ? (
            <FormField
              label="Expected HTTP status code"
              value={state.expectedStatusCode}
              onChangeText={(expectedStatusCode) => change({ expectedStatusCode }, ['expectedStatusCode'])}
              placeholder={String(DEFAULTS.expectedStatusCode)}
              inputMode="numeric"
              error={errors.expectedStatusCode}
            />
          ) : null}
          <FormField
            label="Check interval (seconds)"
            value={state.checkInterval}
            onChangeText={(checkInterval) => change({ checkInterval }, ['checkInterval'])}
            placeholder={String(DEFAULTS.checkInterval)}
            inputMode="numeric"
            hint={`Between ${LIMITS.intervalMinSeconds} and ${LIMITS.intervalMaxSeconds} seconds.`}
            error={errors.checkInterval}
          />
          <FormField
            label="Group (optional)"
            value={state.groupName}
            onChangeText={(groupName) => change({ groupName }, ['groupName'])}
            placeholder="e.g. Production"
            maxLength={LIMITS.groupMaxLength}
            error={errors.groupName}
          />
        </FormSection>

        {isHttp ? (
          <FormSection title="Authentication">
            <SegmentedControl
              options={AUTH_TYPES}
              value={state.authType}
              onChange={(authType) => change({ authType }, ['authSecret', 'authHeaderName'])}
            />
            {state.authType === 'basic_auth' ? (
              <FormField
                label="Username"
                value={state.authUsername}
                onChangeText={(authUsername) => change({ authUsername }, ['authUsername'])}
                {...PLAIN_INPUT_PROPS}
                error={errors.authUsername}
              />
            ) : null}
            {state.authType === 'custom_header' ? (
              <FormField
                label="Header name"
                value={state.authHeaderName}
                onChangeText={(authHeaderName) => change({ authHeaderName }, ['authHeaderName'])}
                placeholder="X-API-Key"
                {...PLAIN_INPUT_PROPS}
                error={errors.authHeaderName}
              />
            ) : null}
            {state.authType !== 'none' ? (
              <FormField
                label={secretLabel(state.authType)}
                value={state.authSecret}
                onChangeText={(authSecret) => change({ authSecret }, ['authSecret'])}
                placeholder={secretKeep ? 'Leave blank to keep the current value' : undefined}
                {...SECRET_INPUT_PROPS}
                hint={
                  secretKeep
                    ? 'Stored encrypted and never shown. Leave blank to keep it.'
                    : 'Stored encrypted and never shown again.'
                }
                error={errors.authSecret}
              />
            ) : null}
          </FormSection>
        ) : null}

        {isHttp ? (
          <FormSection title="JSON field match (optional)">
            <Hint>
              All assertions must match (AND). A dot-separated path is looked up in the JSON body, e.g.
              data.status. Exact compares trimmed, case-insensitive; Contains is a substring; Regex is a
              pattern (an invalid one never matches).
            </Hint>
            <AssertionListEditor
              rows={state.jsonAssertions}
              onChange={(jsonAssertions) => change({ jsonAssertions }, ['jsonAssertions'])}
              error={errors.jsonAssertions}
            />
          </FormSection>
        ) : null}

        <View style={styles.advanced}>
          <Pressable
            onPress={() => setIsAdvancedExpanded((value) => !value)}
            style={styles.advancedHeader}
            accessibilityRole="button"
            accessibilityState={{ expanded: isAdvancedExpanded }}
            accessibilityLabel="Advanced"
          >
            <Ionicons name="options-outline" size={18} color={colors.text} />
            <Text style={styles.advancedTitle}>Advanced</Text>
            {!isAdvancedExpanded && state.version.isEnabled ? (
              <Text style={styles.advancedBadge}>Version check on</Text>
            ) : null}
            <Ionicons
              name={isAdvancedExpanded ? 'chevron-up' : 'chevron-down'}
              size={18}
              color={colors.textSecondary}
            />
          </Pressable>

          {isAdvancedExpanded ? (
            <View style={styles.advancedBody}>
              <ToggleRow
                label="Version check"
                description="Every N health checks, fetch JSON from a separate URL and read a version field from it. Changes are recorded and notified; a failing version check shows a warning but never marks the endpoint down. Turning it off keeps the settings."
                value={state.version.isEnabled}
                onValueChange={(isEnabled) => changeVersion({ isEnabled }, ADVANCED_FIELDS.slice())}
              />
              {state.version.isEnabled ? (
                <>
                  <FormField
                    label="Version URL"
                    value={state.version.url}
                    onChangeText={(url) => changeVersion({ url }, ['versionUrl'])}
                    placeholder="https://api.example.com/version"
                    inputMode="url"
                    {...PLAIN_INPUT_PROPS}
                    error={errors.versionUrl}
                  />
                  <FormField
                    label="Run every N health checks"
                    value={state.version.everyNChecks}
                    onChangeText={(everyNChecks) => changeVersion({ everyNChecks }, ['versionEveryNChecks'])}
                    placeholder={String(DEFAULTS.everyNChecks)}
                    inputMode="numeric"
                    hint={`Between ${LIMITS.everyNChecksMin} and ${LIMITS.everyNChecksMax}. Also runs on the first check after a change.`}
                    error={errors.versionEveryNChecks}
                  />
                  <FormField
                    label="Version field"
                    value={state.version.versionFieldPath}
                    onChangeText={(versionFieldPath) => changeVersion({ versionFieldPath }, ['versionFieldPath'])}
                    placeholder="data.version"
                    {...PLAIN_INPUT_PROPS}
                    error={errors.versionFieldPath}
                  />
                  <SegmentedControl
                    label="Version check auth"
                    options={AUTH_TYPES}
                    value={state.version.authType}
                    onChange={(authType) => changeVersion({ authType }, ['versionSecret', 'versionAuthHeaderName'])}
                  />
                  {state.version.authType === 'basic_auth' ? (
                    <FormField
                      label="Username"
                      value={state.version.authUsername}
                      onChangeText={(authUsername) => changeVersion({ authUsername })}
                      {...PLAIN_INPUT_PROPS}
                    />
                  ) : null}
                  {state.version.authType === 'custom_header' ? (
                    <FormField
                      label="Header name"
                      value={state.version.authHeaderName}
                      onChangeText={(authHeaderName) => changeVersion({ authHeaderName }, ['versionAuthHeaderName'])}
                      placeholder="X-API-Key"
                      {...PLAIN_INPUT_PROPS}
                      error={errors.versionAuthHeaderName}
                    />
                  ) : null}
                  {state.version.authType !== 'none' ? (
                    <FormField
                      label={secretLabel(state.version.authType)}
                      value={state.version.secret}
                      onChangeText={(secret) => changeVersion({ secret }, ['versionSecret'])}
                      placeholder={versionSecretKeep ? 'Leave blank to keep the current value' : undefined}
                      {...SECRET_INPUT_PROPS}
                      hint={
                        versionSecretKeep
                          ? "Separate from the endpoint's own auth. Leave blank to keep the current value."
                          : "Separate from the endpoint's own auth. Stored encrypted and never shown again."
                      }
                      error={errors.versionSecret}
                    />
                  ) : null}
                  <Text style={styles.subheading}>Version assertions (optional, all must match)</Text>
                  <AssertionListEditor
                    rows={state.version.assertions}
                    onChange={(assertions) => changeVersion({ assertions }, ['versionAssertions'])}
                    error={errors.versionAssertions}
                    itemLabel="Version assertion"
                  />
                </>
              ) : null}
            </View>
          ) : null}
        </View>

        {errorCount > 0 ? (
          <FieldError
            message={errorCount === 1 ? 'Fix the highlighted field to save.' : `Fix the ${errorCount} highlighted fields to save.`}
          />
        ) : null}

        <Pressable
          style={({ pressed }) => [styles.saveButton, (pressed || isSaving) && styles.saveButtonPressed]}
          onPress={save}
          disabled={isSaving}
          accessibilityRole="button"
          accessibilityLabel={isEdit ? 'Save changes' : 'Add endpoint'}
        >
          {isSaving ? (
            <ActivityIndicator color="#fff" />
          ) : (
            <Text style={styles.saveButtonText}>{isEdit ? 'Save Changes' : 'Add Endpoint'}</Text>
          )}
        </Pressable>
      </ScrollView>
    </KeyboardAvoidingView>
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
    paddingBottom: 40,
  },
  centered: {
    flex: 1,
    alignItems: 'center',
    justifyContent: 'center',
    backgroundColor: colors.background,
  },
  headerButton: {
    paddingHorizontal: 12,
    paddingVertical: 6,
  },
  headerButtonText: {
    color: colors.primary,
    fontSize: 16,
  },
  headerButtonPrimary: {
    fontWeight: '600',
  },
  errorBox: {
    backgroundColor: `${colors.unhealthy}1a`,
    borderColor: colors.unhealthy,
    borderWidth: 1,
    borderRadius: 10,
    padding: 12,
    gap: 4,
  },
  errorTitle: {
    color: colors.unhealthy,
    fontSize: 14,
    fontWeight: '600',
  },
  errorText: {
    color: colors.unhealthy,
    fontSize: 14,
  },
  advanced: {
    backgroundColor: colors.card,
    borderRadius: 12,
    borderWidth: 1,
    borderColor: colors.border,
  },
  advancedHeader: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 8,
    padding: 16,
  },
  advancedTitle: {
    flex: 1,
    fontSize: 15,
    fontWeight: '600',
    color: colors.text,
  },
  advancedBadge: {
    fontSize: 12,
    color: colors.primary,
    fontWeight: '600',
  },
  advancedBody: {
    paddingHorizontal: 16,
    paddingBottom: 16,
    gap: 14,
  },
  subheading: {
    fontSize: 13,
    fontWeight: '600',
    color: colors.text,
  },
  saveButton: {
    backgroundColor: colors.primary,
    borderRadius: 10,
    paddingVertical: 14,
    alignItems: 'center',
    justifyContent: 'center',
    marginTop: 4,
  },
  saveButtonPressed: {
    opacity: 0.8,
  },
  saveButtonText: {
    color: '#fff',
    fontSize: 16,
    fontWeight: '600',
  },
});
