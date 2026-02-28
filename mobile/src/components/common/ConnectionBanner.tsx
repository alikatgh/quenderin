// =============================================================================
// ConnectionBanner — shows when disconnected/reconnecting
// =============================================================================

import React from 'react';
import { View, Text, Pressable, ActivityIndicator } from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import Feather from 'react-native-vector-icons/Feather';
import { useAppStore } from '../../stores/appStore';
import { useThemedStyles } from '../../theme/useThemedStyles';
import { ThemeColors, ThemeShadows } from '../../theme/palettes';
import { SPACING, TYPOGRAPHY, BORDER_RADIUS } from '../../constants';

interface Props {
  onRetry: () => void;
}

export default function ConnectionBanner({ onRetry }: Props) {
  const styles = useThemedStyles(makeStyles);
  const insets = useSafeAreaInsets();
  const status = useAppStore((s) => s.connectionStatus);

  if (status === 'connected') return null;

  const isConnecting = status === 'connecting';

  return (
    <View style={[styles.banner, { paddingTop: insets.top + SPACING.xs }]}>
      {isConnecting ? (
        <ActivityIndicator size="small" color={styles.bannerText.color} />
      ) : (
        <Feather name="wifi-off" size={14} style={styles.icon} />
      )}
      <Text style={styles.bannerText}>
        {isConnecting ? 'Connecting…' : 'Disconnected'}
      </Text>
      {!isConnecting && (
        <Pressable onPress={onRetry} style={styles.retryBtn}>
          <Text style={styles.retryText}>Retry</Text>
        </Pressable>
      )}
    </View>
  );
}

const makeStyles = (colors: ThemeColors, _shadows: ThemeShadows) =>
  ({
    banner: {
      flexDirection: 'row' as const,
      alignItems: 'center' as const,
      justifyContent: 'center' as const,
      backgroundColor: colors.warningBg,
      paddingHorizontal: SPACING.lg,
      paddingBottom: SPACING.sm,
      gap: SPACING.sm,
    },
    icon: {
      color: colors.warning,
    },
    bannerText: {
      ...TYPOGRAPHY.bodySmall,
      color: colors.warning,
      fontWeight: '600' as const,
    },
    retryBtn: {
      paddingHorizontal: SPACING.md,
      paddingVertical: SPACING.xs,
      borderRadius: BORDER_RADIUS.sm,
      backgroundColor: colors.warning,
    },
    retryText: {
      ...TYPOGRAPHY.labelSmall,
      color: '#FFFFFF',
    },
  }) as const;
