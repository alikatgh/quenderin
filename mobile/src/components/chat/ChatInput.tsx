// =============================================================================
// ChatInput — message composer with send/stop, preset picker, attachment
// =============================================================================

import React, { useState, useRef, useCallback } from 'react';
import {
  View,
  TextInput,
  Pressable,
  Text,
  Keyboard,
  StyleSheet,
} from 'react-native';
import Feather from 'react-native-vector-icons/Feather';
import ReactNativeHapticFeedback from 'react-native-haptic-feedback';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import { useThemedStyles } from '../../theme/useThemedStyles';
import { ThemeColors, ThemeShadows } from '../../theme/palettes';
import { SPACING, BORDER_RADIUS, TYPOGRAPHY } from '../../constants';
import { useChatStore } from '../../stores/chatStore';
import { PRESETS } from '../../types';

interface Props {
  onSend: (text: string) => void;
  onStop: () => void;
}

export default function ChatInput({ onSend, onStop }: Props) {
  const styles = useThemedStyles(makeStyles);
  const insets = useSafeAreaInsets();
  const inputRef = useRef<TextInput>(null);

  const [text, setText] = useState('');
  const isGenerating = useChatStore((s) => s.isGenerating);
  const activePreset = useChatStore((s) => s.activePreset);
  const setActivePreset = useChatStore((s) => s.setActivePreset);

  const handleSend = useCallback(() => {
    const trimmed = text.trim();
    if (!trimmed) return;
    ReactNativeHapticFeedback.trigger('impactLight');
    onSend(trimmed);
    setText('');
    Keyboard.dismiss();
  }, [text, onSend]);

  const handleStop = useCallback(() => {
    ReactNativeHapticFeedback.trigger('impactMedium');
    onStop();
  }, [onStop]);

  return (
    <View style={[styles.wrapper, { paddingBottom: Math.max(insets.bottom, SPACING.sm) }]}>
      {/* Preset chips */}
      <View style={styles.presetsRow}>
        {PRESETS.map((p) => (
          <Pressable
            key={p.id}
            onPress={() => {
              ReactNativeHapticFeedback.trigger('selection');
              setActivePreset(p.id);
            }}
            style={[styles.chip, activePreset === p.id && styles.chipActive]}
          >
            <Feather
              name={p.icon}
              size={12}
              style={[styles.chipIcon, activePreset === p.id && styles.chipIconActive]}
            />
            <Text style={[styles.chipLabel, activePreset === p.id && styles.chipLabelActive]}>
              {p.label}
            </Text>
          </Pressable>
        ))}
      </View>

      {/* Input row */}
      <View style={styles.inputRow}>
        <TextInput
          ref={inputRef}
          style={styles.input}
          value={text}
          onChangeText={setText}
          placeholder="Ask Quenderin…"
          placeholderTextColor={styles.placeholder.color}
          multiline
          maxLength={4096}
          editable={!isGenerating}
          returnKeyType="send"
          blurOnSubmit
          onSubmitEditing={handleSend}
        />
        {isGenerating ? (
          <Pressable onPress={handleStop} style={styles.sendBtn}>
            <View style={styles.stopIcon} />
          </Pressable>
        ) : (
          <Pressable
            onPress={handleSend}
            style={[styles.sendBtn, !text.trim() && styles.sendBtnDisabled]}
            disabled={!text.trim()}
          >
            {text.trim() ? (
              <Feather name="arrow-up" size={20} style={styles.sendIcon} />
            ) : (
              <Feather name="arrow-up" size={20} style={styles.sendIconDisabled} />
            )}
          </Pressable>
        )}
      </View>
    </View>
  );
}

const makeStyles = (colors: ThemeColors, _shadows: ThemeShadows) =>
  ({
    wrapper: {
      backgroundColor: colors.background,
      borderTopWidth: StyleSheet.hairlineWidth,
      borderTopColor: colors.border,
      paddingTop: SPACING.sm,
      paddingHorizontal: SPACING.lg,
    },
    presetsRow: {
      flexDirection: 'row' as const,
      gap: SPACING.xs,
      marginBottom: SPACING.sm,
      flexWrap: 'wrap' as const,
    },
    chip: {
      flexDirection: 'row' as const,
      alignItems: 'center' as const,
      paddingHorizontal: SPACING.md,
      paddingVertical: SPACING.xs + 2,
      borderRadius: BORDER_RADIUS.full,
      backgroundColor: colors.surfaceLight,
    },
    chipActive: {
      backgroundColor: colors.primaryBg,
    },
    chipIcon: {
      color: colors.textMuted,
      marginRight: 4,
    },
    chipIconActive: {
      color: colors.primary,
    },
    chipLabel: {
      ...TYPOGRAPHY.labelSmall,
      color: colors.textMuted,
    },
    chipLabelActive: {
      color: colors.primary,
    },
    inputRow: {
      flexDirection: 'row' as const,
      alignItems: 'flex-end' as const,
      gap: SPACING.sm,
    },
    input: {
      flex: 1,
      ...TYPOGRAPHY.body,
      color: colors.text,
      backgroundColor: colors.inputBg,
      borderWidth: 1,
      borderColor: colors.inputBorder,
      borderRadius: BORDER_RADIUS.lg,
      paddingHorizontal: SPACING.lg,
      paddingTop: SPACING.md,
      paddingBottom: SPACING.md,
      maxHeight: 120,
      minHeight: 44,
    },
    placeholder: {
      color: colors.placeholder,
    },
    sendBtn: {
      width: 44,
      height: 44,
      borderRadius: BORDER_RADIUS.full,
      backgroundColor: colors.primary,
      alignItems: 'center' as const,
      justifyContent: 'center' as const,
    },
    sendBtnDisabled: {
      backgroundColor: colors.surfaceLight,
    },
    sendIcon: {
      color: '#FFFFFF',
    },
    sendIconDisabled: {
      color: colors.textDisabled,
    },
    stopIcon: {
      width: 14,
      height: 14,
      borderRadius: 2,
      backgroundColor: '#FFFFFF',
    },
  }) as const;
