/**
 * Session status HUD for the DSH desktop app.
 *
 * Host half: folds live Session events into one small status snapshot, writes
 * it to a JSON file, and keeps a borderless always-on-top WPF window (hud.ps1)
 * showing it. Windows notifications are raised on the transitions that need the
 * user's attention. Nothing here touches the session log.
 */
import {
  appendFileSync,
  existsSync,
  readFileSync,
  mkdirSync,
  renameSync,
  rmSync,
  statSync,
  writeFileSync,
} from 'node:fs'
import { basename, dirname, join } from 'node:path'
import { tmpdir } from 'node:os'
import { fileURLToPath } from 'node:url'

export const inject = ['sessions', 'subprocess', 'timer', 'webServer']

const PLUGIN_DIR = dirname(fileURLToPath(import.meta.url))
const HUD_SCRIPT = join(PLUGIN_DIR, 'hud.ps1')
const NOTIFY_SCRIPT = join(PLUGIN_DIR, 'notify.ps1')

const TOOL_LABELS = {
  read: '读取文件',
  read_image: '查看图片',
  write: '写入文件',
  edit: '修改文件',
  glob: '查找文件',
  grep: '搜索代码',
  bash: '执行命令',
  pwsh: '执行命令',
  web_search: '联网搜索',
  web_fetch: '抓取网页',
  subagent: '委派子任务',
  subagent_fork: '委派子任务',
  workflow: '运行工作流',
  todo_write: '更新任务列表',
  present: '整理交付物',
  skill: '加载技能',
  ask_user_question: '等待你回答',
  create_goal: '设定目标',
  update_goal: '更新目标',
  schedule_create: '创建定时任务',
  schedule_update: '更新定时任务',
  office_docx: '处理文档',
  office_xlsx: '处理表格',
  office_pptx: '处理演示',
  office_export_pdf: '导出 PDF',
}

const STATE_TEXT = {
  running: '运行中',
  waiting: '需要你确认',
  done: '已完成',
  error: '出错',
  idle: '空闲',
}

function readOptions(config) {
  const c = config && typeof config === 'object' ? config : {}
  const bool = (value, fallback) => (typeof value === 'boolean' ? value : fallback)
  const num = (value, fallback) => (typeof value === 'number' && Number.isFinite(value) ? value : fallback)
  return {
    hud: bool(c.hud, true),
    notifications: bool(c.notifications, true),
    notifyWaiting: bool(c.notifyWaiting, true),
    notifyError: bool(c.notifyError, true),
    notifyDone: bool(c.notifyDone, true),
    sound: bool(c.sound, false),
    minNotifyMs: num(c.minNotifyMs, 8000),
    finishedLingerMs: num(c.finishedLingerMs, 120000),
    idleResetMs: num(c.idleResetMs, 90000),
    autoShowMs: num(c.autoShowMs, 2500),
    eventLingerMs: num(c.eventLingerMs, 8000),
    maxSessions: Math.max(1, num(c.maxSessions, 6)),
    position: typeof c.position === 'string' ? c.position : 'top-center',
    appId: typeof c.appId === 'string' ? c.appId : 'com.deepseek.dsh',
    dataDir: typeof c.dataDir === 'string' && c.dataDir ? c.dataDir : '',
  }
}

function resolveDataDir(configured) {
  if (configured) return configured
  const base = process.env.LOCALAPPDATA || process.env.APPDATA || tmpdir()
  return join(base, 'dsh-status-hud')
}

function trimText(text, max = 28) {
  const flat = String(text).replace(/\s+/g, ' ').trim()
  return flat.length > max ? `${flat.slice(0, max)}…` : flat
}

function parseArguments(raw) {
  if (typeof raw !== 'string') return raw && typeof raw === 'object' ? raw : undefined
  try {
    return JSON.parse(raw)
  } catch {
    return undefined
  }
}

function commandHint(command) {
  if (typeof command !== 'string') return ''
  const firstLine = command.split(/\r?\n/)[0].trim()
  // Drop leading `VAR=value` assignments so the hint starts at the command.
  const stripped = firstLine.replace(/^(?:[A-Za-z_][A-Za-z0-9_]*=[^\s]*\s+)+/, '')
  return trimText(stripped || firstLine, 26)
}

function argumentHint(name, args) {
  if (!args || typeof args !== 'object') return ''
  if (name === 'bash' || name === 'pwsh') return commandHint(args.command)
  const candidate =
    args.pattern ?? args.query ?? args.file_path ?? args.path ?? args.url ?? args.description ?? args.name
  return typeof candidate === 'string' ? trimText(candidate) : ''
}

function describeTool(name, rawArguments) {
  const label = TOOL_LABELS[name] || name
  const hint = argumentHint(name, parseArguments(rawArguments))
  return hint ? `${label} · ${hint}` : `${label}…`
}

function sessionName(header) {
  const cwd = header && typeof header.cwd === 'string' ? header.cwd : ''
  if (cwd) {
    const tail = basename(cwd.replace(/[\\/]+$/, ''))
    if (tail) return tail
  }
  const id = header && typeof header.id === 'string' ? header.id : ''
  return id ? `会话 ${id.slice(-6)}` : '会话'
}

function normalizeState(reason) {
  const kind = reason && typeof reason === 'object' ? reason.kind : reason
  if (kind === 'error') return 'error'
  return 'done'
}

function terminalDetail(reason) {
  const kind = reason && typeof reason === 'object' ? reason.kind : reason
  if (kind === 'error') {
    const message = reason && reason.error && reason.error.message
    return message ? trimText(message, 40) : '本轮出错'
  }
  if (kind === 'aborted') return '已中止'
  if (kind === 'max-tokens') return '达到长度上限'
  if (kind === 'blocked') return '被拦截'
  return '回复完成'
}

function formatDuration(ms) {
  const total = Math.max(0, Math.round(ms / 1000))
  const m = Math.floor(total / 60)
  const s = total % 60
  if (m >= 60) {
    const h = Math.floor(m / 60)
    return `${h} 小时 ${m % 60} 分`
  }
  return m > 0 ? `${m} 分 ${s} 秒` : `${s} 秒`
}

export function apply(ctx, config = {}) {
  const options = readOptions(config)
  const dataDir = resolveDataDir(options.dataDir)
  const statusFile = join(dataDir, 'status.json')
  const orderFile = join(dataDir, 'order.json')
  const signalFile = join(dataDir, 'event.signal')
  const logFile = join(dataDir, 'dsh-status-hud.log')

  try {
    mkdirSync(dataDir, { recursive: true })
  } catch {
    /* a read-only profile must not break activation */
  }

  function log(message) {
    try {
      const stamp = new Date().toISOString()
      if (existsSync(logFile) && statSync(logFile).size > 200_000) rmSync(logFile, { force: true })
      appendFileSync(logFile, `${stamp} ${message}\n`)
    } catch {
      /* diagnostics are best effort */
    }
  }

  const entries = new Map()
  let hudProcess = null
  let hudFailures = 0
  let disposed = false
  let publishTimer = null
  let lastPublishAt = 0
  let lastSnapshotKey = ''
  let pendingEvent = null
  const lastNotifyAt = new Map()

  // Column order and manual removals survive a restart: the session log gives
  // back titles and counters, but nothing in it says where a column stood.
  const savedOrder = []
  const hiddenUntil = new Map()

  function loadState() {
    try {
      const raw = readFileSync(orderFile, 'utf8')
      const parsed = JSON.parse(raw)
      if (Array.isArray(parsed.order)) {
        for (const id of parsed.order) if (typeof id === 'string' && !savedOrder.includes(id)) savedOrder.push(id)
      }
      if (parsed.hidden && typeof parsed.hidden === 'object') {
        for (const [id, at] of Object.entries(parsed.hidden)) hiddenUntil.set(id, Number(at) || 0)
      }
    } catch {
      /* first run */
    }
  }

  function saveState() {
    try {
      const payload = JSON.stringify({ order: savedOrder, hidden: Object.fromEntries(hiddenUntil) })
      const tmp = `${orderFile}.tmp`
      writeFileSync(tmp, payload, 'utf8')
      renameSync(tmp, orderFile)
    } catch (error) {
      log(`state save failed: ${error && error.message}`)
    }
  }

  function orderFor(id) {
    const index = savedOrder.indexOf(id)
    if (index >= 0) return index
    savedOrder.push(id)
    saveState()
    return savedOrder.length - 1
  }

  function isHidden(entry) {
    const at = hiddenUntil.get(entry.id)
    if (!at) return false
    // A turn started after the removal brings the session back.
    return !(entry.startedAt && entry.startedAt > at)
  }

  function hideSession(id) {
    if (!id) return
    hiddenUntil.set(id, Date.now())
    saveState()
  }

  function raiseEvent(kind, entry, text) {
    const at = Date.now()
    pendingEvent = {
      kind,
      text,
      at,
      sid: entry ? entry.id : '',
      session: entry ? entry.title || entry.workspace : '',
    }
    // Fast path: a tiny file the HUD watches at 40ms. It is written before the
    // throttled snapshot, so the panel reacts long before the poll catches up.
    try {
      writeFileSync(signalFile, JSON.stringify({ at, kind, sid: pendingEvent.sid }), 'utf8')
    } catch (error) {
      log(`signal write failed: ${error && error.message}`)
    }
    publish(true)
  }

  const powershell = join(process.env.SystemRoot || 'C:\\Windows', 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe')

  // A session joins the bar the first time it is used and then stays there.
  // The record of "used at least once" is the order file, so a restart brings
  // back exactly those sessions — never the untouched history.
  async function restoreUsedSessions() {
    const query = ctx.get('sessionQuery')
    if (!query) return
    const wanted = savedOrder.filter((id) => !entries.has(id)).slice(-24)
    if (!wanted.length) return

    const titles = new Map()
    if (typeof query.readTitleSnapshots === 'function') {
      try {
        const observed = await query.readTitleSnapshots(wanted)
        for (const item of observed) {
          if (item && item.status === 'fulfilled' && item.value && item.value.title) {
            titles.set(String(item.sessionId), item.value.title.title)
          }
        }
      } catch (error) {
        log(`title fold failed: ${error && error.message}`)
      }
    }

    const started = Date.now()
    for (const id of wanted) {
      let header = { id }
      let entry = null
      if (typeof query.readSession === 'function' && Date.now() - started < 3000) {
        try {
          const snapshot = await query.readSession(id)
          if (snapshot && snapshot.session) {
            header = snapshot.session
            entry = {
              id,
              order: orderFor(id),
              title: titles.get(id) || '',
              workspace: sessionName(header),
              cwd: typeof header.cwd === 'string' ? header.cwd : '',
              subagent: false,
              parentId: '',
              turns: 0,
              steps: 0,
              tools: 0,
              state: 'idle',
              detail: '',
              startedAt: null,
              endedAt: null,
              lastActive: typeof header.createdAt === 'number' ? header.createdAt : 0,
              lastError: '',
              lastTool: '',
              light: false,
      titleFromLog: false,
            }
            foldHistory(entry, { snapshotEvents: () => snapshot.events || [] })
          }
        } catch {
          /* the session may be gone; drop it from the order */
        }
      }
      if (!entry) continue
      if (!entry.title) entry.title = entry.workspace
      entries.set(id, entry)
    }
    log(`restored ${entries.size} used session(s)`)
    publish(true)
  }

  // ---------------------------------------------------------------- snapshot

  function readTitle(session) {
    try {
      const service = ctx.get('sessionTitle')
      if (!service || typeof service.get !== 'function') return ''
      const snapshot = service.get(session)
      return snapshot && typeof snapshot.title === 'string' ? snapshot.title : ''
    } catch {
      return ''
    }
  }

  function titleFromEvents(events) {
    for (const event of events) {
      if (event.type !== 'user/message') continue
      const blocks = event.data && event.data.message && event.data.message.content
      if (!Array.isArray(blocks)) continue
      const text = blocks
        .filter((block) => block && block.type === 'text' && typeof block.text === 'string')
        .map((block) => block.text)
        .join(' ')
        .replace(/\s+/g, ' ')
        .trim()
      if (text) return trimText(text, 24)
    }
    return ''
  }

  // A restarted plugin must not restart the counters: the session log already
  // holds the real turn/step/tool history, so fold it once when the entry is
  // created and keep counting from there.
  function foldHistory(entry, session) {
    let events = []
    try {
      events = typeof session.snapshotEvents === 'function' ? session.snapshotEvents() : []
    } catch {
      events = []
    }
    let lastStart = null
    let lastEnd = null
    let lastTool = ''
    for (const event of events) {
      const time = typeof event.time === 'number' ? event.time : 0
      if (time > entry.lastActive) entry.lastActive = time
      switch (event.type) {
        case 'turn/start':
          entry.turns = Math.max(entry.turns, Number(event.data && event.data.turn) || entry.turns + 1)
          lastStart = time
          break
        case 'step/start':
          entry.steps += 1
          break
        case 'tool/call':
          entry.tools += 1
          lastTool = describeTool(event.data.name, event.data.arguments)
          break
        case 'turn/end':
          lastEnd = { time, reason: event.data && event.data.reason }
          break
        default:
          break
      }
    }
    if (lastEnd) {
      entry.state = normalizeState(lastEnd.reason)
      entry.endedAt = lastEnd.time
      entry.startedAt = lastStart
      entry.detail = terminalDetail(lastEnd.reason)
    } else if (lastStart) {
      entry.state = 'done'
      entry.endedAt = lastStart
      entry.startedAt = lastStart
      entry.detail = '回复完成'
    }
    if (lastTool) entry.lastTool = lastTool
    if (!entry.title) entry.title = titleFromEvents(events)
  }

  function entryFor(session) {
    const id = String(session.id)
    const existing = entries.get(id)
    if (existing) return existing
    const header = session.header || {}
    const entry = {
      id,
      order: orderFor(id),
      title: '',
      workspace: sessionName({ ...header, id }),
      cwd: typeof header.cwd === 'string' ? header.cwd : '',
      subagent: header.origin === 'subagent' || Boolean(header.parentSession),
      parentId: header.parentSession ? String(header.parentSession) : '',
      turns: 0,
      steps: 0,
      tools: 0,
      state: 'idle',
      detail: '',
      startedAt: null,
      endedAt: null,
      lastActive: typeof header.createdAt === 'number' ? header.createdAt : Date.now(),
      light: false,
      titleFromLog: false,
      lastError: '',
      lastTool: '',
    }
    foldHistory(entry, session)
    entry.title = readTitle(session) || entry.title || entry.workspace
    entries.set(id, entry)
    return entry
  }

  function factsOf(entry, subagentCount) {
    const facts = []
    if (entry.turns) facts.push(`第 ${entry.turns} 轮`)
    if (entry.steps) facts.push(`${entry.steps} 步`)
    if (entry.tools) facts.push(`${entry.tools} 次工具`)
    if (subagentCount) facts.push(`子代理 ${subagentCount}`)
    return facts.join(' · ')
  }

  function viewOf(entry, subagentCount) {
    const terminal = entry.state === 'done' || entry.state === 'error'
    return {
      id: entry.id,
      title: entry.title || '新会话 ' + entry.id.slice(-4),
      workspace: entry.workspace,
      cwd: entry.cwd,
      state: entry.state,
      stateText: STATE_TEXT[entry.state] || entry.state,
      detail: entry.detail || '',
      elapsedFrom: entry.startedAt,
      elapsedTo: terminal ? entry.endedAt : null,
      elapsedLabel: entry.state === 'running' || entry.state === 'waiting' ? '已跑' : terminal ? '用时' : '',
      turns: entry.turns,
      steps: entry.steps,
      tools: entry.tools,
      subagents: subagentCount,
      facts: factsOf(entry, subagentCount),
    }
  }

  function buildSnapshot() {
    const now = Date.now()
    const all = [...entries.values()]

    // Membership: the sessions touched most recently. Display order: entry
    // order, so a state change never moves a column under the pointer.
    const members = all
      .filter((entry) => !entry.subagent && !isHidden(entry))
      .sort((a, b) => (b.lastActive || 0) - (a.lastActive || 0))
      .slice(0, options.maxSessions)
      .sort((a, b) => a.order - b.order)

    const subagentCounts = new Map()
    for (const entry of all) {
      if (!entry.subagent || !entry.parentId) continue
      if (entry.state !== 'running' && entry.state !== 'waiting') continue
      subagentCounts.set(entry.parentId, (subagentCounts.get(entry.parentId) || 0) + 1)
    }

    const sessions = members.map((entry) => viewOf(entry, subagentCounts.get(entry.id) || 0))
    return {
      v: 4,
      sessions,
      idleText: '空闲',
      countText: sessions.length > 1 ? `共 ${sessions.length} 个会话` : '',
      event: pendingEvent && now - pendingEvent.at < options.eventLingerMs ? pendingEvent : null,
      autoShowMs: options.autoShowMs,
      hint: '单击跳转 · 按住右键移除',
      updatedAt: now,
    }
  }

  function publish(force = false) {
    if (disposed) return
    if (force) {
      if (publishTimer) { clearTimeout(publishTimer); publishTimer = null }
    } else if (publishTimer) {
      return
    }
    const wait = force ? 0 : Math.max(0, 180 - (Date.now() - lastPublishAt))
    publishTimer = setTimeout(() => {
      publishTimer = null
      lastPublishAt = Date.now()
      // Build at fire time: a queued write must publish the freshest state,
      // and a forced publish must never be dropped behind a pending timer.
      const snapshot = buildSnapshot()
      const key =
        snapshot.sessions
          .map((s) => `${s.id}:${s.state}:${s.title}:${s.detail}:${s.elapsedFrom}:${s.elapsedTo}`)
          .join('|') + `#${snapshot.event ? snapshot.event.at : 0}`
      if (!force && key === lastSnapshotKey) return
      if (writeSnapshot(snapshot)) {
        lastSnapshotKey = key
      } else {
        lastSnapshotKey = ''
        if (!disposed) ctx.timer.timeout(() => publish(true), 150)
      }
    }, wait)
  }

  function writeSnapshot(snapshot) {
    const payload = JSON.stringify(snapshot)
    const tmp = `${statusFile}.tmp`
    try {
      writeFileSync(tmp, payload, 'utf8')
      renameSync(tmp, statusFile)
      return true
    } catch (error) {
      // The reader may hold the file open for a moment; fall back to an
      // in-place write so the state never stays stale.
      try {
        writeFileSync(statusFile, payload, 'utf8')
        return true
      } catch (inner) {
        log(`status write failed: ${error && error.message} / ${inner && inner.message}`)
        return false
      }
    }
  }

  // -------------------------------------------------------------- hud window

  function ensureHud() {
    if (!options.hud || disposed || hudProcess) return
    if (process.platform !== 'win32') return
    try {
      const handle = ctx.subprocess.spawn({
        argv: [
          powershell,
          '-NoProfile',
          '-NonInteractive',
          '-ExecutionPolicy',
          'Bypass',
          '-WindowStyle',
          'Hidden',
          '-File',
          HUD_SCRIPT,
          '-StatusPath',
          statusFile,
          '-Anchor',
          options.position,
          '-OpenUrl',
          origin ? `${origin}/session-status-hud/request` : '',
          '-HideUrl',
          origin ? `${origin}/session-status-hud/hide` : '',
        ],
        cwd: PLUGIN_DIR,
        stdio: {
          stdin: 'ignore',
          stdout: { maxBytes: 16 * 1024 },
          stderr: { maxBytes: 16 * 1024 },
        },
        graceMs: 2500,
      })
      hudProcess = handle
      hudFailures = 0
      log('hud spawned')
      handle.done.then((outcome) => {
        hudProcess = null
        const stderrText = readCollected(handle.collected && handle.collected.stderr)
        log(`hud exited code=${outcome.exitCode} ${stderrText ? `stderr=${stderrText}` : ''}`)
        if (disposed) return
        hudFailures += 1
        if (hudFailures <= 3) ctx.timer.timeout(() => ensureHud(), 2000)
        else log('hud restart budget exhausted')
      }, (error) => {
        hudProcess = null
        hudFailures += 1
        log(`hud spawn rejected: ${error && error.message}`)
        if (!disposed && hudFailures <= 3) ctx.timer.timeout(() => ensureHud(), 2000)
      })
    } catch (error) {
      log(`hud spawn threw: ${error && error.message}`)
    }
  }

  function readCollected(reader) {
    if (!reader) return ''
    try {
      const read = reader.readFrom(0)
      return read && read.text ? read.text.trim().slice(-400) : ''
    } catch {
      return ''
    }
  }

  function stopHud() {
    const handle = hudProcess
    hudProcess = null
    if (!handle) return
    try {
      handle.terminate()
    } catch {
      /* already gone */
    }
  }

  // ------------------------------------------------------------ notification

  function notify(kind, entry, extra) {
    if (!options.notifications || disposed) return
    if (process.platform !== 'win32') return
    const titles = {
      waiting: 'DSH · 需要你确认',
      error: 'DSH · 出错了',
      done: 'DSH · 已完成',
    }
    if (kind === 'waiting' && !options.notifyWaiting) return
    if (kind === 'error' && !options.notifyError) return
    if (kind === 'done' && !options.notifyDone) return

    const key = `${kind}:${entry.id}`
    const now = Date.now()
    if (now - (lastNotifyAt.get(key) || 0) < 3000) return
    lastNotifyAt.set(key, now)

    const minutes = entry.startedAt ? formatDuration((entry.endedAt || now) - entry.startedAt) : ''
    const body = [entry.title || entry.workspace, extra || entry.detail, minutes && `用时 ${minutes}`].filter(Boolean).join(' · ')

    try {
      const handle = ctx.subprocess.spawn({
        argv: [
          powershell,
          '-NoProfile',
          '-NonInteractive',
          '-ExecutionPolicy',
          'Bypass',
          '-File',
          NOTIFY_SCRIPT,
          '-AppId',
          options.appId,
          '-Title',
          titles[kind] || 'DSH',
          '-Body',
          trimText(body, 120),
          ...(options.sound ? ['-Sound'] : []),
        ],
        cwd: PLUGIN_DIR,
        stdio: { stdin: 'ignore', stdout: 'ignore', stderr: { maxBytes: 8 * 1024 } },
        graceMs: 2000,
      })
      handle.done.then((outcome) => {
        if (outcome.exitCode !== 0) log(`notify failed: ${readCollected(handle.collected && handle.collected.stderr)}`)
      }, () => {})
    } catch (error) {
      log(`notify threw: ${error && error.message}`)
    }
  }

  // ------------------------------------------------------------------ events

  ctx.on('session/event', (session, event) => {
    try {
      const entry = entryFor(session)
      if (entry.light) {
        // Seeded from the corpus without a live Session; fold the real log now.
        foldHistory(entry, session)
        entry.title = readTitle(session) || entry.title
        entry.light = false
      }
      const now = Date.now()
      entry.lastActive = now
      switch (event.type) {
        case 'turn/start': {
          entry.state = 'running'
          entry.startedAt = event.time
          entry.endedAt = null
          entry.turns += 1
          entry.detail = '思考中…'
          entry.title = readTitle(session) || entry.title
          hudFailures = 0
          ensureHud()
          break
        }
        case 'step/start': {
          entry.steps += 1
          break
        }
        case 'tool/call': {
          entry.state = 'running'
          entry.tools += 1
          if (!entry.startedAt) entry.startedAt = event.time
          entry.detail = describeTool(event.data.name, event.data.arguments)
          // The question tool is the reliable "waiting for you" signal: the
          // user-questions waterfall carries no agent in its payload.
          if (event.data.name === 'ask_user_question') {
            entry.state = 'waiting'
            entry.detail = '等待你回答问题'
            entry.askCallId = String(event.data.callId)
            if (!entry.subagent) {
              raiseEvent('waiting', entry, `${entry.title || entry.workspace} · 等待你回答问题`)
              notify('waiting', entry, '等待你回答问题')
            }
          }
          break
        }
        case 'tool/result': {
          const failed = event.data && event.data.error
          const callId =
            event.data && event.data.message && event.data.message.source ? String(event.data.message.source.callId) : ''
          if (entry.askCallId && callId === entry.askCallId) {
            entry.askCallId = ''
            entry.state = 'running'
            entry.detail = '继续处理…'
          } else {
            entry.detail = failed ? '工具调用失败，正在处理…' : '处理结果中…'
          }
          break
        }
        case 'assistant/message': {
          if (entry.state === 'running') entry.detail = '整理回复…'
          break
        }
        case 'turn/end': {
          const reason = event.data && event.data.reason
          const kind = reason && typeof reason === 'object' ? reason.kind : reason
          entry.state = normalizeState(reason)
          entry.endedAt = event.time
          const elapsed = entry.startedAt ? event.time - entry.startedAt : 0
          entry.detail = terminalDetail(reason)
          entry.title = readTitle(session) || entry.title
          if (!entry.subagent) {
            if (entry.state === 'error') {
              raiseEvent('error', entry, `${entry.title || entry.workspace} 出错 · ${entry.detail}`)
              notify('error', entry)
            } else if (kind !== 'aborted') {
              raiseEvent('done', entry, `${entry.title || entry.workspace} 已完成 · 用时 ${formatDuration(elapsed)}`)
              if (elapsed >= options.minNotifyMs) notify('done', entry)
            }
          }
          break
        }
        default:
          break
      }
      publish()
    } catch (error) {
      log(`session/event handler failed: ${error && error.message}`)
    }
  })

  ctx.on('agent/status', (payload) => {
    try {
      const agent = payload && payload.agent
      if (!agent) return
      const entry = entries.get(String(agent.id))
      if (!entry) return
      // Only a real turn boundary decides "done". The agent reports idle in
      // the gaps between steps, so treating idle as finished makes a long
      // turn flicker green/blue.
      if (payload.status === 'running') {
        if (entry.state !== 'running' && entry.state !== 'waiting') {
          entry.state = 'running'
          entry.startedAt = entry.startedAt || Date.now()
          entry.endedAt = null
          entry.detail = entry.detail || '思考中…'
        }
      }
      entry.lastActive = Date.now()
      publish()
    } catch (error) {
      log(`agent/status handler failed: ${error && error.message}`)
    }
  })

  ctx.on('agent/error', (payload) => {
    try {
      const agent = payload && payload.agent
      if (!agent) return
      const entry = entries.get(String(agent.id))
      if (!entry) return
      const message = payload.error && payload.error.message ? trimText(payload.error.message, 40) : '运行出错'
      entry.state = 'error'
      entry.endedAt = Date.now()
      entry.detail = message
      entry.lastError = message
      if (!entry.subagent) raiseEvent('error', entry, `${entry.title || entry.workspace} 出错 · ${message}`)
      publish()
      if (!entry.subagent) notify('error', entry, message)
    } catch (error) {
      log(`agent/error handler failed: ${error && error.message}`)
    }
  })

  // Waiting states are observed through the waterfalls that ask the user; the
  ctx.on('approval/request', (request, next) => {
    try {
      const agent = (request && request.agent) || ctx.agents.currentInitiator()
      log(`approval seen agent=${agent ? agent.id : 'none'} tool=${(request && request.toolName) || '?'}`)
      markWaiting(agent, '等待你批准操作')
    } catch (error) {
      log(`approval observe failed: ${error && error.message}`)
    }
    return next()
  })

  ctx.on('user-questions/request', (request, next) => {
    try {
      const agent = (request && request.agent) || ctx.agents.currentInitiator()
      log(`question seen agent=${agent ? agent.id : 'none'}`)
      markWaiting(agent, '等待你回答问题')
    } catch (error) {
      log(`question observe failed: ${error && error.message}`)
    }
    return next()
  })

  function markWaiting(agent, detail) {
    if (!agent) return
    const entry = entries.get(String(agent.id))
    if (!entry) return
    entry.state = 'waiting'
    entry.detail = detail
    entry.askCallId = ''
    entry.lastActive = Date.now()
    if (!entry.subagent) raiseEvent('waiting', entry, `${entry.title || entry.workspace} · ${detail}`)
    publish()
    if (!entry.subagent) notify('waiting', entry, detail)
  }

  ctx.on('session/disposed', (session) => {
    try {
      entries.delete(String(session.id))
      publish()
    } catch {
      /* ignore */
    }
  })

  // ------------------------------------------------------------ click bridge
  //
  // The HUD is a separate process and the session switch is a page action, so
  // the click travels HUD -> these routes -> the client half of this bundle,
  // which calls uiWorkspace.openSession().
  let pendingOpen = null
  let origin = ''
  try {
    origin = ctx.webServer.getOrigin()
  } catch (error) {
    log(`webServer origin unavailable: ${error && error.message}`)
  }

  function respondJson(res, value) {
    try {
      res.setHeader('content-type', 'application/json; charset=utf-8')
      res.setHeader('cache-control', 'no-store')
      res.end(JSON.stringify(value))
    } catch {
      /* the socket may be gone */
    }
  }

  const disposeRequest = ctx.webServer.register({
    kind: 'exact',
    path: '/session-status-hud/request',
    handler: (req, res) => {
      let session = ''
      try {
        session = new URL(req.url || '/', 'http://localhost').searchParams.get('session') || ''
      } catch {
        session = ''
      }
      if (session) pendingOpen = { session, at: Date.now() }
      respondJson(res, { ok: Boolean(session) })
    },
  })

  const disposeHide = ctx.webServer.register({
    kind: 'exact',
    path: '/session-status-hud/hide',
    handler: (req, res) => {
      let session = ''
      try {
        session = new URL(req.url || '/', 'http://localhost').searchParams.get('session') || ''
      } catch {
        session = ''
      }
      hideSession(session)
      publish(true)
      respondJson(res, { ok: Boolean(session) })
    },
  })

  const disposePending = ctx.webServer.register({
    kind: 'exact',
    path: '/session-status-hud/pending',
    handler: (req, res) => {
      const fresh = pendingOpen && Date.now() - pendingOpen.at < 5000 ? pendingOpen.session : ''
      pendingOpen = null
      respondJson(res, { session: fresh })
    },
  })

  const disposeDebug = ctx.webServer.register({
    kind: 'exact',
    path: '/session-status-hud/debug',
    handler: (req, res) => {
      const out = { ok: true }
      try {
        const table = ctx.get('clientModules')
        if (table) {
          out.clientPath = table.clientPath('@local/session-status-hud') || null
          const graph = table.graph ? table.graph() : null
          out.ids = graph && graph.entries ? graph.entries.map((entry) => entry.id) : []
        } else {
          out.clientPath = 'no-clientModules'
        }
      } catch (error) {
        out.error = String((error && error.message) || error)
      }
      respondJson(res, out)
    },
  })

  ctx.effect(() => () => {
    disposeRequest()
    disposeHide()
    disposePending()
    disposeDebug()
  })

  // Titles are generated asynchronously; retry the ones still unnamed.
  async function refreshTitles() {
    const query = ctx.get('sessionQuery')
    if (!query || typeof query.readTitleSnapshots !== 'function') return
    const pending = [...entries.values()]
      .filter((e) => !e.subagent && !e.titleFromLog && (e.titleTries || 0) < 10)
      .slice(0, 8)
    for (const entry of pending) entry.titleTries = (entry.titleTries || 0) + 1
    if (!pending.length) return
    try {
      const observed = await query.readTitleSnapshots(pending.map((e) => e.id))
      let changed = false
      for (const item of observed) {
        if (!item || item.status !== 'fulfilled' || !item.value || !item.value.title) continue
        const title = item.value.title.title
        if (!title) continue
        const entry = entries.get(String(item.sessionId))
        if (entry && entry.title !== title) {
          entry.title = title
          entry.titleFromLog = true
          changed = true
        }
      }
      if (changed) publish(true)
    } catch {
      /* the next round retries */
    }
  }

  // Never invent "done": a long tool run can go minutes without events. Only
  // a session that is no longer open is retired to idle, and only after a
  // generous quiet period.
  ctx.timer.interval(() => {
    const now = Date.now()
    const live = new Set()
    try {
      for (const session of ctx.sessions.list()) live.add(String(session.id))
    } catch {
      /* keep the previous set */
    }
    let changed = false
    for (const entry of [...entries.values()]) {
      if (entry.subagent) continue
      const active = entry.state === 'running' || entry.state === 'waiting'
      if (!active) continue
      if (live.has(entry.id)) continue
      if (now - entry.lastActive < options.finishedLingerMs) continue
      entry.state = 'idle'
      entry.endedAt = null
      entry.detail = '会话已关闭'
      changed = true
    }
    if (changed) publish(true)
    else publish()
    void refreshTitles()
  }, 15_000)

  ctx.effect(() => {
    loadState()
    // Seed every live session so the panel shows the real set of open
    // conversations instead of only the ones that happen to run afterwards.
    try {
      for (const session of ctx.sessions.list()) {
        const header = session.header || {}
        if (header.origin === 'subagent' || header.parentSession) continue
        entryFor(session)
      }
    } catch (error) {
      log(`seed failed: ${error && error.message}`)
    }
    ensureHud()
    publish(true)
    void restoreUsedSessions()
    return () => {
      disposed = true
      if (publishTimer) clearTimeout(publishTimer)
      publishTimer = null
      stopHud()
    }
  })

  log(`activated hud=${options.hud} notifications=${options.notifications} dir=${dataDir}`)
  try {
    const moduleTable = ctx.get('clientModules')
    const clientPath =
      moduleTable && typeof moduleTable.clientPath === 'function'
        ? moduleTable.clientPath('@local/session-status-hud')
        : undefined
    log(`client module: ${clientPath || 'NOT REGISTERED'}`)
  } catch (error) {
    log(`client module probe failed: ${error && error.message}`)
  }
}
