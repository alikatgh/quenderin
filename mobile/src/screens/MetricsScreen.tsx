// =============================================================================
// MetricsScreen — shows agent run history
// =============================================================================

import React, { useEffect, useCallback } from 'react';
import {
  View,
  Text,
  FlatList,
  RefreshControl,
} from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import Feather from 'react-native-vector-icons/Feather';
import { useChatStore } from '../stores/chatStore';
import { useAgentSocket } from '../hooks/useAgentSocket';
import { useThemedStyles } from '../theme/useThemedStyles';
import { ThemeColors, ThemeShadows } from '../theme/palettes';
import { SPACING, BORDER_RADIUS, TYPOGRAPHY } from '../constants';
import type { MetricRecord } from '../types';

export default function MetricsScreen() {
  const styles = useThemedStyles(makeStyles);
  const insets = useSafeAreaInsets();
  const metrics = useChatStore((s) => s.metrics);
  const { requestMetrics } = useAgentSocket({ subscribe: false });

  useEffect(() => {
    requestMetrics();
  }, [requestMetrics]);

  const renderItem = useCallback(
    ({ item }: { item: MetricRecord }) => (
      <View style={styles.card}>
        <View style={styles.cardHeader}>
          <View
            style={[
              styles.statusBadge,
              item.success ? styles.successBadge : styles.failBadge,
            ]}
          >
            <Feather
              name={item.success ? 'check' : 'x'}
              size={10}
              color={item.success ? '#059669' : '#DC2626'}
            />
          </View>
          <Text style={styles.goalText} numberOfLines={2}>
            {item.goal_text}
          </Text>
        </View>
        <View style={styles.cardMeta}>
          <Text style={styles.metaText}>
            {item.total_steps} steps · {(item.duration_ms / 1000).toFixed(1)}s
            {item.total_retries > 0 ? ` · ${item.total_retries} retries` : ''}
          </Text>
          <Text style={styles.metaText}>
            {new Date(item.timestamp).toLocaleDateString()}
          </Text>
        </View>
      </View>
    ),
    [styles],
  );

  const keyExtractor = useCallback((item: MetricRecord) => item.id, []);

  return (
    <View style={styles.container}>
      <FlatList
        data={metrics}
        renderItem={renderItem}
        keyExtractor={keyExtractor}
        style={styles.list}
        contentContainerStyle={[
          styles.listContent,
          { paddingTop: insets.top + SPACING.lg, paddingBottom: insets.bottom + SPACING.xl },
        ]}
        refreshControl={
          <RefreshControl refreshing={false} onRefresh={requestMetrics} />
        }
        ListHeaderComponent={
          <Text style={styles.title}>Metrics</Text>
        }
        ListEmptyComponent={
          <View style={styles.empty}>
            <Feather name="bar-chart-2" size={40} style={styles.emptyIcon} />
            <Text style={styles.emptyText}>No runs yet</Text>
            <Text style={styles.emptySubtext}>
              Send a message to start recording metrics
            </Text>
          </View>
        }
      />
    </View>
  );
}

const makeStyles = (colors: ThemeColors, shadows: ThemeShadows) =>
  ({
    container: { flex: 1, backgroundColor: colors.background },
    list: { flex: 1 },
    listContent: { paddingHorizontal: SPACING.lg },
    title: {
      ...TYPOGRAPHY.h1,
      color: colors.text,
      marginBottom: SPACING.lg,
    },
    card: {
      backgroundColor: colors.surface,
      borderRadius: BORDER_RADIUS.md,
      padding: SPACING.lg,
      marginBottom: SPACING.sm,
      ...shadows.small,
    } as any,
    cardHeader: {
      flexDirection: 'row' as const,
      alignItems: 'flex-start' as const,
      gap: SPACING.sm,
    },
    statusBadge: {
      width: 20,
      height: 20,
      borderRadius: 10,
      alignItems: 'center' as const,
      justifyContent: 'center' as const,
      marginTop: 2,
    },
    successBadge: { backgroundColor: colors.successBg },
    failBadge: { backgroundColor: colors.errorBg },
    goalText: {
      ...TYPOGRAPHY.body,
      color: colors.text,
      flex: 1,
    },
    cardMeta: {
      flexDirection: 'row' as const,
      justifyContent: 'space-between' as const,
      marginTop: SPACING.sm,
    },
    metaText: {
      ...TYPOGRAPHY.meta,
      color: colors.textMuted,
    },
    empty: {
      alignItems: 'center' as const,
      paddingTop: 80,
    },
    emptyIcon: { color: colors.textDisabled, marginBottom: SPACING.lg },
    emptyText: { ...TYPOGRAPHY.h2, color: colors.textMuted, marginBottom: SPACING.xs },
    emptySubtext: { ...TYPOGRAPHY.bodySmall, color: colors.textDisabled, textAlign: 'center' as const },
  }) as const;
