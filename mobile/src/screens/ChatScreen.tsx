// =============================================================================
// ChatScreen — main conversation view
// =============================================================================

import React, { useRef, useEffect, useCallback } from 'react';
import {
  FlatList,
  KeyboardAvoidingView,
  Platform,
} from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import { useThemedStyles } from '../theme/useThemedStyles';
import { ThemeColors, ThemeShadows } from '../theme/palettes';
import { useChatStore } from '../stores/chatStore';
import { useAgentSocket } from '../hooks/useAgentSocket';
import ChatMessage from '../components/chat/ChatMessage';
import ChatInput from '../components/chat/ChatInput';
import ConnectionBanner from '../components/common/ConnectionBanner';
import RequiredActionSheet from '../components/common/RequiredActionSheet';
import type { LogEntry } from '../types';

export default function ChatScreen() {
  const styles = useThemedStyles(makeStyles);
  const insets = useSafeAreaInsets();
  const listRef = useRef<FlatList<LogEntry>>(null);

  const logs = useChatStore((s) => s.logs);
  const requiredAction = useChatStore((s) => s.requiredAction);
  const setRequiredAction = useChatStore((s) => s.setRequiredAction);

  const { sendChat, stopGeneration, triggerAction, connect } = useAgentSocket();

  // Auto-scroll to bottom on new messages
  const logsLen = logs.length;
  const lastMsg = logs[logsLen - 1]?.message?.length ?? 0;
  useEffect(() => {
    if (logsLen > 0) {
      // Small delay to let FlatList render
      const t = setTimeout(() => {
        listRef.current?.scrollToEnd({ animated: true });
      }, 80);
      return () => clearTimeout(t);
    }
  }, [logsLen, lastMsg]);

  const renderItem = useCallback(
    ({ item }: { item: LogEntry }) => <ChatMessage entry={item} />,
    [],
  );

  const keyExtractor = useCallback((item: LogEntry) => item.id, []);

  return (
    <KeyboardAvoidingView
      style={styles.container}
      behavior={Platform.OS === 'ios' ? 'padding' : undefined}
      keyboardVerticalOffset={0}
    >
      <ConnectionBanner onRetry={connect} />

      <FlatList
        ref={listRef}
        data={logs}
        renderItem={renderItem}
        keyExtractor={keyExtractor}
        style={styles.list}
        contentContainerStyle={[
          styles.listContent,
          { paddingTop: insets.top + 8 },
        ]}
        showsVerticalScrollIndicator={false}
        keyboardDismissMode="interactive"
        keyboardShouldPersistTaps="handled"
        maintainVisibleContentPosition={{
          minIndexForVisible: 0,
          autoscrollToTopThreshold: 10,
        }}
      />

      <ChatInput onSend={sendChat} onStop={stopGeneration} />

      {requiredAction && (
        <RequiredActionSheet
          action={requiredAction}
          onTrigger={triggerAction}
          onDismiss={() => setRequiredAction(null)}
        />
      )}
    </KeyboardAvoidingView>
  );
}

const makeStyles = (colors: ThemeColors, _shadows: ThemeShadows) =>
  ({
    container: {
      flex: 1,
      backgroundColor: colors.background,
    },
    list: {
      flex: 1,
    },
    listContent: {
      paddingBottom: 8,
    },
  }) as const;
