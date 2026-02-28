// =============================================================================
// SettingsScreen — server URL, theme, context size, privacy
// =============================================================================

import React, { useState } from 'react';
import {
  View,
  Text,
  TextInput,
  ScrollView,
  Pressable,
  Switch,
  StyleSheet,
} from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import Feather from 'react-native-vector-icons/Feather';
import ReactNativeHapticFeedback from 'react-native-haptic-feedback';
import { useAppStore } from '../stores/appStore';
import { useThemedStyles } from '../theme/useThemedStyles';
import { ThemeColors, ThemeShadows } from '../theme/palettes';
import { SPACING, BORDER_RADIUS, TYPOGRAPHY } from '../constants';
import WebSocketService from '../services/websocket';

export default function SettingsScreen() {
  const styles = useThemedStyles(makeStyles);
  const insets = useSafeAreaInsets();

  const settings = useAppStore((s) => s.settings);
  const updateSettings = useAppStore((s) => s.updateSettings);
  const serverUrl = useAppStore((s) => s.serverUrl);
  const setServerUrl = useAppStore((s) => s.setServerUrl);

  const [urlDraft, setUrlDraft] = useState(serverUrl);

  const handleSaveUrl = () => {
    const trimmed = urlDraft.trim();
    if (trimmed && trimmed !== serverUrl) {
      setServerUrl(trimmed);
      WebSocketService.shared().connect(trimmed);
      ReactNativeHapticFeedback.trigger('notificationSuccess');
    }
  };

  const themeOptions: Array<{ value: 'light' | 'dark' | 'system'; label: string; icon: string }> = [
    { value: 'system', label: 'System', icon: 'smartphone' },
    { value: 'light', label: 'Light', icon: 'sun' },
    { value: 'dark', label: 'Dark', icon: 'moon' },
  ];

  const contextOptions = [512, 1024, 2048, 4096];

  return (
    <ScrollView
      style={styles.container}
      contentContainerStyle={[
        styles.content,
        { paddingTop: insets.top + SPACING.lg, paddingBottom: insets.bottom + SPACING.xl },
      ]}
    >
      {/* Header */}
      <Text style={styles.title}>Settings</Text>

      {/* Server URL */}
      <Text style={styles.sectionLabel}>SERVER URL</Text>
      <View style={styles.urlRow}>
        <TextInput
          style={styles.urlInput}
          value={urlDraft}
          onChangeText={setUrlDraft}
          autoCapitalize="none"
          autoCorrect={false}
          keyboardType="url"
          placeholder="ws://192.168.1.x:3002"
          placeholderTextColor={styles.placeholder.color}
        />
        <Pressable onPress={handleSaveUrl} style={styles.saveBtn}>
          <Feather name="check" size={18} style={styles.saveBtnIcon} />
        </Pressable>
      </View>

      {/* Theme */}
      <Text style={styles.sectionLabel}>THEME</Text>
      <View style={styles.optionRow}>
        {themeOptions.map((opt) => (
          <Pressable
            key={opt.value}
            onPress={() => {
              ReactNativeHapticFeedback.trigger('selection');
              updateSettings({ themePreference: opt.value });
            }}
            style={[
              styles.optionCard,
              settings.themePreference === opt.value && styles.optionCardActive,
            ]}
          >
            <Feather
              name={opt.icon}
              size={20}
              style={[
                styles.optionIcon,
                settings.themePreference === opt.value && styles.optionIconActive,
              ]}
            />
            <Text
              style={[
                styles.optionLabel,
                settings.themePreference === opt.value && styles.optionLabelActive,
              ]}
            >
              {opt.label}
            </Text>
          </Pressable>
        ))}
      </View>

      {/* Context Size */}
      <Text style={styles.sectionLabel}>CONTEXT SIZE</Text>
      <View style={styles.optionRow}>
        {contextOptions.map((size) => (
          <Pressable
            key={size}
            onPress={() => {
              ReactNativeHapticFeedback.trigger('selection');
              updateSettings({ contextSize: size });
            }}
            style={[
              styles.contextChip,
              settings.contextSize === size && styles.contextChipActive,
            ]}
          >
            <Text
              style={[
                styles.contextChipText,
                settings.contextSize === size && styles.contextChipTextActive,
              ]}
            >
              {size}
            </Text>
          </Pressable>
        ))}
      </View>

      {/* Toggles */}
      <Text style={styles.sectionLabel}>PRIVACY & SAFETY</Text>
      <View style={styles.toggleRow}>
        <View style={styles.toggleInfo}>
          <Text style={styles.toggleLabel}>Memory Safety</Text>
          <Text style={styles.toggleDesc}>Limit context window to prevent OOM</Text>
        </View>
        <Switch
          value={settings.memorySafetyEnabled}
          onValueChange={(v) => updateSettings({ memorySafetyEnabled: v })}
          trackColor={{ false: styles.switchTrack.color, true: styles.switchTrackActive.color }}
        />
      </View>

      <View style={styles.toggleRow}>
        <View style={styles.toggleInfo}>
          <Text style={styles.toggleLabel}>Privacy Lock</Text>
          <Text style={styles.toggleDesc}>Require passphrase to access app</Text>
        </View>
        <Switch
          value={settings.privacyLockEnabled}
          onValueChange={(v) => updateSettings({ privacyLockEnabled: v })}
          trackColor={{ false: styles.switchTrack.color, true: styles.switchTrackActive.color }}
        />
      </View>
    </ScrollView>
  );
}

const makeStyles = (colors: ThemeColors, _shadows: ThemeShadows) =>
  ({
    container: {
      flex: 1,
      backgroundColor: colors.background,
    },
    content: {
      paddingHorizontal: SPACING.lg,
    },
    title: {
      ...TYPOGRAPHY.h1,
      color: colors.text,
      marginBottom: SPACING.xl,
    },
    sectionLabel: {
      ...TYPOGRAPHY.label,
      color: colors.textMuted,
      marginTop: SPACING.xl,
      marginBottom: SPACING.sm,
    },
    urlRow: {
      flexDirection: 'row' as const,
      gap: SPACING.sm,
    },
    urlInput: {
      flex: 1,
      ...TYPOGRAPHY.body,
      color: colors.text,
      backgroundColor: colors.inputBg,
      borderWidth: 1,
      borderColor: colors.inputBorder,
      borderRadius: BORDER_RADIUS.md,
      paddingHorizontal: SPACING.lg,
      paddingVertical: SPACING.md,
    },
    placeholder: { color: colors.placeholder },
    saveBtn: {
      width: 44,
      height: 44,
      borderRadius: BORDER_RADIUS.md,
      backgroundColor: colors.primary,
      alignItems: 'center' as const,
      justifyContent: 'center' as const,
    },
    saveBtnIcon: { color: '#FFFFFF' },
    optionRow: {
      flexDirection: 'row' as const,
      gap: SPACING.sm,
    },
    optionCard: {
      flex: 1,
      alignItems: 'center' as const,
      paddingVertical: SPACING.lg,
      borderRadius: BORDER_RADIUS.md,
      backgroundColor: colors.surface,
      borderWidth: 1,
      borderColor: colors.border,
    },
    optionCardActive: {
      borderColor: colors.primary,
      backgroundColor: colors.primaryBg,
    },
    optionIcon: { color: colors.textMuted, marginBottom: SPACING.xs },
    optionIconActive: { color: colors.primary },
    optionLabel: { ...TYPOGRAPHY.bodySmall, color: colors.textMuted },
    optionLabelActive: { color: colors.primary, fontWeight: '600' as const },
    contextChip: {
      paddingHorizontal: SPACING.lg,
      paddingVertical: SPACING.sm,
      borderRadius: BORDER_RADIUS.full,
      backgroundColor: colors.surfaceLight,
    },
    contextChipActive: { backgroundColor: colors.primaryBg },
    contextChipText: { ...TYPOGRAPHY.bodySmall, color: colors.textMuted },
    contextChipTextActive: { color: colors.primary, fontWeight: '600' as const },
    toggleRow: {
      flexDirection: 'row' as const,
      alignItems: 'center' as const,
      justifyContent: 'space-between' as const,
      paddingVertical: SPACING.lg,
      borderBottomWidth: StyleSheet.hairlineWidth,
      borderBottomColor: colors.borderLight,
    },
    toggleInfo: { flex: 1, marginRight: SPACING.lg },
    toggleLabel: { ...TYPOGRAPHY.body, color: colors.text },
    toggleDesc: { ...TYPOGRAPHY.meta, color: colors.textMuted, marginTop: 2 },
    switchTrack: { color: colors.surfaceLight },
    switchTrackActive: { color: colors.primary },
  }) as const;
