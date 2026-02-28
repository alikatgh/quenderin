// =============================================================================
// RequiredActionSheet — bottom sheet for model downloads / actions
// =============================================================================

import React from 'react';
import { View, Text, Pressable } from 'react-native';
import BottomSheet, { BottomSheetView } from '@gorhom/bottom-sheet';
import Feather from 'react-native-vector-icons/Feather';
import ReactNativeHapticFeedback from 'react-native-haptic-feedback';
import { useThemedStyles } from '../../theme/useThemedStyles';
import { ThemeColors, ThemeShadows } from '../../theme/palettes';
import { SPACING, BORDER_RADIUS, TYPOGRAPHY } from '../../constants';
import type { RequiredAction } from '../../types';

interface Props {
  action: RequiredAction;
  onTrigger: (code: string) => void;
  onDismiss: () => void;
}

export default function RequiredActionSheet({ action, onTrigger, onDismiss }: Props) {
  const styles = useThemedStyles(makeStyles);

  const handleAction = () => {
    ReactNativeHapticFeedback.trigger('impactMedium');
    onTrigger(action.code);
  };

  return (
    <BottomSheet
      snapPoints={['40%']}
      enablePanDownToClose
      onClose={onDismiss}
      backgroundStyle={styles.sheetBg}
      handleIndicatorStyle={styles.handle}
    >
      <BottomSheetView style={styles.content}>
        <View style={styles.iconWrap}>
          <Feather name="download" size={28} style={styles.icon} />
        </View>
        <Text style={styles.title}>{action.title}</Text>
        <Text style={styles.message}>{action.message}</Text>

        <Pressable onPress={handleAction} style={styles.actionBtn}>
          <Text style={styles.actionBtnText}>Continue</Text>
        </Pressable>

        <Pressable onPress={onDismiss} style={styles.dismissBtn}>
          <Text style={styles.dismissBtnText}>Dismiss</Text>
        </Pressable>
      </BottomSheetView>
    </BottomSheet>
  );
}

const makeStyles = (colors: ThemeColors, _shadows: ThemeShadows) =>
  ({
    sheetBg: {
      backgroundColor: colors.card,
    },
    handle: {
      backgroundColor: colors.textMuted,
    },
    content: {
      padding: SPACING.xl,
      alignItems: 'center' as const,
    },
    iconWrap: {
      width: 56,
      height: 56,
      borderRadius: BORDER_RADIUS.full,
      backgroundColor: colors.primaryBg,
      alignItems: 'center' as const,
      justifyContent: 'center' as const,
      marginBottom: SPACING.lg,
    },
    icon: {
      color: colors.primary,
    },
    title: {
      ...TYPOGRAPHY.h2,
      color: colors.text,
      textAlign: 'center' as const,
      marginBottom: SPACING.sm,
    },
    message: {
      ...TYPOGRAPHY.body,
      color: colors.textSecondary,
      textAlign: 'center' as const,
      marginBottom: SPACING.xl,
    },
    actionBtn: {
      width: '100%' as const,
      paddingVertical: SPACING.lg,
      borderRadius: BORDER_RADIUS.md,
      backgroundColor: colors.primary,
      alignItems: 'center' as const,
      marginBottom: SPACING.md,
    },
    actionBtnText: {
      ...TYPOGRAPHY.h3,
      color: '#FFFFFF',
    },
    dismissBtn: {
      paddingVertical: SPACING.sm,
    },
    dismissBtnText: {
      ...TYPOGRAPHY.body,
      color: colors.textMuted,
    },
  }) as const;
