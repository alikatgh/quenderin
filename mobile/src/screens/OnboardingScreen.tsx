// =============================================================================
// OnboardingScreen — first-launch server setup
// =============================================================================

import React, { useState } from 'react';
import { View, Text, TextInput, Pressable } from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import Feather from 'react-native-vector-icons/Feather';
import ReactNativeHapticFeedback from 'react-native-haptic-feedback';
import { useAppStore } from '../stores/appStore';
import WebSocketService from '../services/websocket';
import { useThemedStyles } from '../theme/useThemedStyles';
import { ThemeColors, ThemeShadows } from '../theme/palettes';
import { SPACING, BORDER_RADIUS, TYPOGRAPHY } from '../constants';

function isValidWebSocketUrl(input: string): boolean {
  try {
    const parsed = new URL(input);
    return parsed.protocol === 'ws:' || parsed.protocol === 'wss:';
  } catch {
    return false;
  }
}

export default function OnboardingScreen() {
  const styles = useThemedStyles(makeStyles);
  const insets = useSafeAreaInsets();

  const setServerUrl = useAppStore((s) => s.setServerUrl);
  const completeOnboarding = useAppStore((s) => s.completeOnboarding);

  const [url, setUrl] = useState('ws://localhost:3002');
  const [step, setStep] = useState(0);
  const [urlError, setUrlError] = useState<string | null>(null);

  const steps = [
    {
      icon: 'cpu',
      title: 'Welcome to Quenderin',
      subtitle: 'Your private AI assistant with local LLM inference. No cloud, no data leaks.',
    },
    {
      icon: 'wifi',
      title: 'Connect to Server',
      subtitle: 'Enter the WebSocket URL of your Quenderin server running on your local network.',
      hasInput: true,
    },
    {
      icon: 'shield',
      title: 'Fully Private',
      subtitle: 'All inference runs on your own hardware. Your conversations never leave your network.',
    },
  ];

  const currentStep = steps[step];

  const handleNext = () => {
    if (step === 1) {
      const trimmed = url.trim();
      if (!isValidWebSocketUrl(trimmed)) {
        setUrlError('Enter a valid ws:// or wss:// URL');
        ReactNativeHapticFeedback.trigger('notificationError');
        return;
      }
      setUrlError(null);
      setServerUrl(trimmed);
      WebSocketService.shared().connect(trimmed);
    }

    if (step < steps.length - 1) {
      ReactNativeHapticFeedback.trigger('impactLight');
      setStep(step + 1);
    } else {
      ReactNativeHapticFeedback.trigger('notificationSuccess');
      completeOnboarding();
    }
  };

  return (
    <View style={[styles.container, { paddingTop: insets.top, paddingBottom: insets.bottom }]}>
      <View style={styles.body}>
        {/* Icon */}
        <View style={styles.iconWrap}>
          <Feather name={currentStep.icon} size={40} style={styles.icon} />
        </View>

        {/* Text */}
        <Text style={styles.title}>{currentStep.title}</Text>
        <Text style={styles.subtitle}>{currentStep.subtitle}</Text>

        {/* Input (step 1 only) */}
        {currentStep.hasInput && (
          <>
            <TextInput
              style={[styles.input, urlError && styles.inputError]}
              value={url}
              onChangeText={(text) => {
                setUrl(text);
                if (urlError) setUrlError(null);
              }}
              autoCapitalize="none"
              autoCorrect={false}
              keyboardType="url"
              placeholder="ws://192.168.1.x:3002"
              placeholderTextColor={styles.placeholder.color}
            />
            {urlError && <Text style={styles.errorText}>{urlError}</Text>}
          </>
        )}
      </View>

      {/* Dots */}
      <View style={styles.dotsRow}>
        {steps.map((_, i) => (
          <View key={i} style={[styles.dot, i === step && styles.dotActive]} />
        ))}
      </View>

      {/* Button */}
      <Pressable onPress={handleNext} style={styles.nextBtn}>
        <Text style={styles.nextBtnText}>
          {step === steps.length - 1 ? 'Get Started' : 'Continue'}
        </Text>
        <Feather name="arrow-right" size={18} style={styles.nextBtnIcon} />
      </Pressable>
    </View>
  );
}

const makeStyles = (colors: ThemeColors, _shadows: ThemeShadows) =>
  ({
    container: {
      flex: 1,
      backgroundColor: colors.background,
      paddingHorizontal: SPACING.xl,
    },
    body: {
      flex: 1,
      justifyContent: 'center' as const,
      alignItems: 'center' as const,
    },
    iconWrap: {
      width: 80,
      height: 80,
      borderRadius: BORDER_RADIUS.full,
      backgroundColor: colors.primaryBg,
      alignItems: 'center' as const,
      justifyContent: 'center' as const,
      marginBottom: SPACING.xl,
    },
    icon: { color: colors.primary },
    title: {
      ...TYPOGRAPHY.h1,
      color: colors.text,
      textAlign: 'center' as const,
      marginBottom: SPACING.sm,
    },
    subtitle: {
      ...TYPOGRAPHY.body,
      color: colors.textSecondary,
      textAlign: 'center' as const,
      lineHeight: 22,
      maxWidth: 300,
    },
    input: {
      width: '100%' as const,
      ...TYPOGRAPHY.body,
      color: colors.text,
      backgroundColor: colors.inputBg,
      borderWidth: 1,
      borderColor: colors.inputBorder,
      borderRadius: BORDER_RADIUS.md,
      paddingHorizontal: SPACING.lg,
      paddingVertical: SPACING.lg,
      marginTop: SPACING.xl,
      textAlign: 'center' as const,
    },
    inputError: {
      borderColor: colors.error,
    },
    errorText: {
      ...TYPOGRAPHY.meta,
      color: colors.error,
      marginTop: SPACING.sm,
      textAlign: 'center' as const,
    },
    placeholder: { color: colors.placeholder },
    dotsRow: {
      flexDirection: 'row' as const,
      justifyContent: 'center' as const,
      gap: SPACING.sm,
      marginBottom: SPACING.xl,
    },
    dot: {
      width: 8,
      height: 8,
      borderRadius: 4,
      backgroundColor: colors.surfaceLight,
    },
    dotActive: {
      backgroundColor: colors.primary,
      width: 24,
    },
    nextBtn: {
      flexDirection: 'row' as const,
      alignItems: 'center' as const,
      justifyContent: 'center' as const,
      backgroundColor: colors.primary,
      paddingVertical: SPACING.lg,
      borderRadius: BORDER_RADIUS.md,
      marginBottom: SPACING.lg,
      gap: SPACING.sm,
    },
    nextBtnText: {
      ...TYPOGRAPHY.h3,
      color: '#FFFFFF',
    },
    nextBtnIcon: { color: '#FFFFFF' },
  }) as const;
