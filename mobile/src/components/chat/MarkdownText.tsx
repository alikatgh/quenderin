// =============================================================================
// MarkdownText — renders markdown in native text with streaming cursor
// =============================================================================

import React, { memo } from 'react';
import { View, Text, StyleSheet } from 'react-native';
import Markdown from 'react-native-markdown-display';
import { useTheme } from '../../theme';
import {
  TYPOGRAPHY,
  SPACING,
  BORDER_RADIUS,
  MAX_MARKDOWN_RENDER_CHARS,
} from '../../constants';

interface Props {
  content: string;
  isStreaming?: boolean;
}

function MarkdownText({ content, isStreaming }: Props) {
  const { colors } = useTheme();
  const safeContent =
    content.length > MAX_MARKDOWN_RENDER_CHARS
      ? `${content.slice(0, MAX_MARKDOWN_RENDER_CHARS)}\n\n…[truncated]`
      : content;

  const mdStyles = StyleSheet.create({
    body: { ...TYPOGRAPHY.body, color: colors.text },
    heading1: {
      ...TYPOGRAPHY.h1,
      color: colors.text,
      marginTop: SPACING.lg,
      marginBottom: SPACING.sm,
    },
    heading2: {
      ...TYPOGRAPHY.h2,
      color: colors.text,
      marginTop: SPACING.md,
      marginBottom: SPACING.xs,
    },
    heading3: {
      ...TYPOGRAPHY.h3,
      color: colors.text,
      marginTop: SPACING.sm,
      marginBottom: SPACING.xs,
    },
    code_inline: {
      ...TYPOGRAPHY.code,
      color: colors.primary,
      backgroundColor: colors.surfaceLight,
      borderRadius: 4,
      paddingHorizontal: 4,
      paddingVertical: 1,
    },
    fence: {
      ...TYPOGRAPHY.code,
      color: colors.text,
      backgroundColor: colors.surfaceLight,
      borderRadius: BORDER_RADIUS.sm,
      padding: SPACING.md,
      marginVertical: SPACING.sm,
      overflow: 'hidden' as const,
    },
    blockquote: {
      borderLeftWidth: 3,
      borderLeftColor: colors.primary,
      paddingLeft: SPACING.md,
      marginVertical: SPACING.sm,
      backgroundColor: colors.primaryBg,
      borderRadius: BORDER_RADIUS.sm,
      padding: SPACING.sm,
    },
    link: {
      color: colors.primary,
      textDecorationLine: 'underline' as const,
    },
    list_item: {
      flexDirection: 'row' as const,
      marginVertical: 2,
    },
    strong: {
      fontWeight: '600' as const,
    },
    em: {
      fontStyle: 'italic' as const,
    },
  });

  return (
    <View>
      <Markdown style={mdStyles}>{safeContent || ' '}</Markdown>
      {isStreaming && (
        <Text
          style={{
            color: colors.primary,
            fontSize: 16,
            lineHeight: 20,
          }}
        >
          ▋
        </Text>
      )}
    </View>
  );
}

export default memo(MarkdownText);
