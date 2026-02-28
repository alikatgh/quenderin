// =============================================================================
// ChatMessage — renders a single log entry (user, assistant, status, error)
// =============================================================================

import React, { memo } from 'react';
import { View, Text, StyleSheet, Pressable } from 'react-native';
import Feather from 'react-native-vector-icons/Feather';
import ReactNativeHapticFeedback from 'react-native-haptic-feedback';
import Clipboard from '@react-native-clipboard/clipboard';
import { useThemedStyles } from '../../theme/useThemedStyles';
import { ThemeColors, ThemeShadows } from '../../theme/palettes';
import { SPACING, BORDER_RADIUS } from '../../constants';
import { TYPOGRAPHY } from '../../constants';
import type { LogEntry } from '../../types';
import MarkdownText from './MarkdownText';

interface Props {
  entry: LogEntry;
}

function ChatMessage({ entry }: Props) {
  const styles = useThemedStyles(makeStyles);
  const isUser = entry.type === 'chat';
  const isError = entry.type === 'error';
  const isStatus = entry.type === 'status';
  const isAssistant =
    entry.type === 'chat_response' || entry.type === 'chat_stream';

  const handleLongPress = () => {
    if (entry.message) {
      Clipboard.setString(entry.message);
      ReactNativeHapticFeedback.trigger('notificationSuccess');
    }
  };

  if (isStatus) {
    return (
      <View style={styles.statusRow}>
        <Feather name="info" size={12} style={styles.statusIcon} />
        <Text style={styles.statusText} numberOfLines={2}>
          {entry.message}
        </Text>
      </View>
    );
  }

  return (
    <Pressable onLongPress={handleLongPress} style={styles.container}>
      <View style={[styles.bubble, isUser && styles.userBubble, isError && styles.errorBubble]}>
        {/* Label */}
        <Text style={[styles.label, isUser && styles.userLabel]}>
          {isUser ? 'You' : isError ? 'Error' : 'Quenderin'}
        </Text>

        {/* Content */}
        {isAssistant ? (
          <MarkdownText
            content={entry.message}
            isStreaming={entry.isStreaming}
          />
        ) : (
          <Text style={[styles.body, isError && styles.errorText]}>
            {entry.message}
          </Text>
        )}

        {/* Generation meta */}
        {entry.meta && (
          <View style={styles.metaRow}>
            <Text style={styles.metaText}>
              {entry.meta.tokenCount} tokens · {(entry.meta.durationMs / 1000).toFixed(1)}s ·{' '}
              {entry.meta.tokensPerSecond.toFixed(1)} t/s
            </Text>
          </View>
        )}
      </View>
    </Pressable>
  );
}

const makeStyles = (colors: ThemeColors, shadows: ThemeShadows) =>
  ({
    container: {
      marginBottom: SPACING.sm,
      paddingHorizontal: SPACING.lg,
    },
    bubble: {
      backgroundColor: colors.surface,
      borderRadius: BORDER_RADIUS.lg,
      padding: SPACING.lg,
      ...shadows.small,
    } as any,
    userBubble: {
      backgroundColor: colors.primaryBg,
      marginLeft: 40,
    },
    errorBubble: {
      backgroundColor: colors.errorBg,
    },
    label: {
      ...TYPOGRAPHY.labelSmall,
      color: colors.primary,
      textTransform: 'uppercase' as const,
      marginBottom: SPACING.xs,
    },
    userLabel: {
      color: colors.textMuted,
    },
    body: {
      ...TYPOGRAPHY.body,
      color: colors.text,
    },
    errorText: {
      color: colors.error,
    },
    metaRow: {
      marginTop: SPACING.sm,
      borderTopWidth: StyleSheet.hairlineWidth,
      borderTopColor: colors.borderLight,
      paddingTop: SPACING.xs,
    },
    metaText: {
      ...TYPOGRAPHY.metaSmall,
      color: colors.textMuted,
    },
    statusRow: {
      flexDirection: 'row' as const,
      alignItems: 'center' as const,
      paddingHorizontal: SPACING.lg,
      paddingVertical: SPACING.xs,
    },
    statusIcon: {
      color: colors.textMuted,
      marginRight: SPACING.xs,
    },
    statusText: {
      ...TYPOGRAPHY.meta,
      color: colors.textMuted,
      flex: 1,
    },
  }) as const;

export default memo(ChatMessage);
