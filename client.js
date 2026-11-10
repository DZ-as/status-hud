/**
 * Client half of the session status HUD.
 *
 * The desktop HUD is a separate process, so a click on a session row reaches
 * this page through the host routes /session-status-hud/request and /pending,
 * and the page performs the actual navigation.
 */
window.__ModuleLoader__.load({
  id: '@local/session-status-hud',
  factory(require) {
    return {
      inject: ['uiWorkspace', 'timer'],
      apply(ctx) {
        const poll = async () => {
          try {
            const response = await fetch('/session-status-hud/pending', { cache: 'no-store' })
            if (!response.ok) return
            const data = await response.json()
            const session = data && data.session
            if (!session) return
            try {
              ctx.uiWorkspace.openSession(session)
            } catch (error) {
              console.warn('[session-status-hud] openSession failed', error)
            }
          } catch {
            /* host not reachable yet; the next tick retries */
          }
        }

        ctx.timer.interval(poll, 350)
      },
    }
  },
})
