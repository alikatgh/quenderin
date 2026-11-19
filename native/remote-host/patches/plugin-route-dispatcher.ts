import type { PluginRouteDispatcher, BotWorkScope } from './plugin-route-bridge.js'
import { mountedBotRead, botReadUnavailable } from './quenderin-bot-runtime.mjs'
import { mountedBotWork } from './quenderin-bot-work-runtime.mjs'
import { BOT_WORK_ENDPOINTS, botWorkUnavailable, validateBotWorkRequest } from './quenderin-bot-work-policy.mjs'
export interface PluginRouteConnectionLike {
  createSharedFetchHandler?(channel: '/api'): { fetch(request: Request, peer?: unknown): Promise<Response> }
  authenticatedUrl?(baseUrl: string): string
}
/** Remote-authenticated scope is passed in process, never through Fetch headers/body. */
export function createPluginRouteDispatcher(readConnection: () => PluginRouteConnectionLike | undefined,
  _readPort: () => number | undefined, peer?: unknown, workScope?: BotWorkScope): PluginRouteDispatcher | undefined {
  if (readConnection() === undefined) return undefined
  const dispatch: PluginRouteDispatcher = async (route, body, signal) => {
    signal.throwIfAborted()
    const connection = readConnection()
    const workRequest = validateBotWorkRequest({ route, body })
    if (workRequest.ok) {
      const mounted = mountedBotWork(connection)
      if (!mounted || !workScope || !mountedBotRead(connection)) return botWorkUnavailable()
      return mounted.call(workRequest.value, workScope, signal)
    }
    if (body && typeof body === 'object' && BOT_WORK_ENDPOINTS.includes((body as { endpoint: string }).endpoint)) return botWorkUnavailable()
    const mounted = mountedBotRead(connection)
    if (!mounted) return botReadUnavailable()
    const handler = connection?.createSharedFetchHandler?.('/api')
    if (!handler) return botReadUnavailable()
    const response = await withSignal(handler.fetch(new Request(`http://127.0.0.1/${route}`, {
      method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(body ?? {}), signal,
    }), peer), signal)
    const text = await response.text()
    if (mountedBotRead(connection) !== mounted || new TextEncoder().encode(text).byteLength > 262144) return botReadUnavailable()
    let json: unknown
    try { json = JSON.parse(text) } catch { return botReadUnavailable() }
    return { status: response.status, json }
  }
  dispatch.quenderinBotReadAvailable = () => {
    const connection = readConnection()
    return mountedBotRead(connection) !== undefined && typeof connection?.createSharedFetchHandler === 'function'
  }
  dispatch.quenderinBotWorkAvailable = () => dispatch.quenderinBotReadAvailable?.() === true && mountedBotWork(readConnection())?.ready() === true
  return dispatch
}
function withSignal<T>(pending: Promise<T>, signal: AbortSignal): Promise<T> {
  return new Promise<T>((resolve, reject) => {
    const onAbort = () => reject(signal.reason)
    signal.addEventListener('abort', onAbort, { once: true })
    if (signal.aborted) onAbort()
    void pending.then(resolve, reject).finally(() => signal.removeEventListener('abort', onAbort))
  })
}
