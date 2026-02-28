// =============================================================================
// WebSocket Service — singleton with subscriber pattern
// Pattern adopted from off-grid-mobile's service layer
// =============================================================================

import { useAppStore } from '../stores/appStore';
import { WS_RECONNECT_DELAY_MS } from '../constants';

export type WSMessage = {
  type: string;
  [key: string]: unknown;
};

type Subscriber = (msg: WSMessage) => void;

class WebSocketService {
  private static instance: WebSocketService;
  private ws: WebSocket | null = null;
  private subscribers = new Set<Subscriber>();
  private reconnectTimer: ReturnType<typeof setTimeout> | null = null;
  private intentionalClose = false;

  static shared(): WebSocketService {
    if (!WebSocketService.instance) {
      WebSocketService.instance = new WebSocketService();
    }
    return WebSocketService.instance;
  }

  // ---------------------------------------------------------------------------
  // Public API
  // ---------------------------------------------------------------------------

  connect(url?: string): void {
    const serverUrl = url ?? useAppStore.getState().serverUrl;
    this.intentionalClose = false;
    this.cleanup();

    useAppStore.getState().setConnectionStatus('connecting');

    const ws = new WebSocket(serverUrl);

    ws.onopen = () => {
      useAppStore.getState().setConnectionStatus('connected');
    };

    ws.onmessage = (event) => {
      try {
        const data: WSMessage =
          typeof event.data === 'string' ? JSON.parse(event.data) : event.data;
        this.notify(data);
      } catch {
        // ignore malformed messages
      }
    };

    ws.onerror = () => {
      // onclose will fire after this
    };

    ws.onclose = () => {
      useAppStore.getState().setConnectionStatus('disconnected');
      this.ws = null;
      if (!this.intentionalClose) {
        this.scheduleReconnect(serverUrl);
      }
    };

    this.ws = ws;
  }

  disconnect(): void {
    this.intentionalClose = true;
    this.cleanup();
    useAppStore.getState().setConnectionStatus('disconnected');
  }

  send(msg: WSMessage): void {
    if (this.ws?.readyState === WebSocket.OPEN) {
      this.ws.send(JSON.stringify(msg));
    }
  }

  subscribe(fn: Subscriber): () => void {
    this.subscribers.add(fn);
    return () => {
      this.subscribers.delete(fn);
    };
  }

  get isConnected(): boolean {
    return this.ws?.readyState === WebSocket.OPEN;
  }

  // ---------------------------------------------------------------------------
  // Internal
  // ---------------------------------------------------------------------------

  private notify(msg: WSMessage): void {
    this.subscribers.forEach((fn) => {
      try {
        fn(msg);
      } catch {
        // subscriber error should not kill others
      }
    });
  }

  private cleanup(): void {
    if (this.reconnectTimer) {
      clearTimeout(this.reconnectTimer);
      this.reconnectTimer = null;
    }
    if (this.ws) {
      this.ws.onopen = null;
      this.ws.onmessage = null;
      this.ws.onerror = null;
      this.ws.onclose = null;
      this.ws.close();
      this.ws = null;
    }
  }

  private scheduleReconnect(url: string): void {
    this.reconnectTimer = setTimeout(() => {
      this.connect(url);
    }, WS_RECONNECT_DELAY_MS);
  }
}

export default WebSocketService;
