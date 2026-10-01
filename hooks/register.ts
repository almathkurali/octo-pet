import type { Register } from 'claude-code'

// Desktop side: pet/Octo.swift. This module keeps one JSON file per session
// under ~/.claude/octo-pet/sessions and acts on the pet's command files.
type State = 'idle' | 'running' | 'needs-input' | 'ready' | 'blocked' | 'gone'

// Tools that are really a question for the person.
const ASKS: Record<string, string> = {
  AskUserQuestion: 'Claude has a question',
  ExitPlanMode: 'Plan ready for review',
}

const short = (tool: string) => tool.replace(/^mcp__.+?__/, '')

export const register: Register = on => {
  let turnId: string | null = null
  let set: (state: State, detail?: string) => Promise<void> = async () => {}
  let togglePet: () => Promise<string> = async () => ''

  on('session.start', async ($, e, next) => {
    const home = (await $.env.get('HOME')) ?? '~'
    const id = await $.session.id()
    const root = `${home}/.claude/octo-pet`
    const file = `${root}/sessions/${id}.json`
    const cmdDir = `${root}/cmd`
    const pidFile = `${root}/pet.pid`
    const hidden = `${root}/hidden` // the person tucked the pet away; /pet wakes it
    const app = `${root}/Octo.app`
    let title = e.cwd.split('/').pop() || e.cwd
    let desktopId: string | null = null
    let recordPath: string | null = null
    let state: State = 'idle'
    let detail = ''
    let since = await $.clock.now()
    let beats = 0

    const write = async () =>
      $.fs.write(file, JSON.stringify({ id, desktopId, title, state, detail, turnId, since, updatedAt: await $.clock.now() }))
    set = async (s, d = '') => {
      state = s
      detail = d
      since = await $.clock.now()
      await write()
    }

    // The desktop app's record of this session: its `local_…` id (what the deep
    // link takes), its title, and when the person last looked at it.
    const syncRecord = async () => {
      if (!recordPath) {
        const dir = `${home}/Library/Application Support/Claude/claude-code-sessions`
        const r = await $.process.run(['grep', '-rl', '--include=local_*.json', id, dir])
        recordPath = r.stdout.split('\n').find(Boolean) ?? null
        if (!recordPath) return
      }
      let rec: { sessionId?: string; title?: string; lastFocusedAt?: number }
      try {
        rec = JSON.parse(await $.fs.read(recordPath))
      } catch {
        return
      }
      desktopId = rec.sessionId ?? desktopId
      title = rec.title || title
      // Ready means finished and not yet seen: looking at the session clears it.
      if (state === 'ready' && (rec.lastFocusedAt ?? 0) > since) await set('idle')
    }

    const petPid = async () => (await $.fs.read(pidFile).catch(() => '')).trim()
    const petAlive = async () => {
      const pid = await petPid()
      return /^\d+$/.test(pid) && (await $.process.run(['kill', '-0', pid])).exitCode === 0
    }

    const launch = async () => {
      const bin = `${app}/Contents/MacOS/Octo`
      const src = `${$.plugin.root}/pet/Octo.swift`
      const stale = !(await $.fs.exists(bin)) || (await $.fs.stat(src)).mtimeMs > (await $.fs.stat(bin)).mtimeMs
      if (stale) {
        $.ui.toast('Octo: building your desktop pet (one time, ~15s)…', { timeoutMs: 8000 })
        const r = await $.process.run(['/bin/sh', `${$.plugin.root}/pet/build.sh`], { timeoutMs: 300_000 })
        if (r.exitCode !== 0) {
          $.ui.toast(`Octo build failed: ${(r.stderr + r.stdout).trim().split('\n').pop()}`, { timeoutMs: 15000 })
          return
        }
      }
      await $.process.run(['open', '-g', '-a', app])
      $.clock.after(6000, async () => {
        if (await petAlive()) return
        const last = (await $.fs.read(`${root}/pet.log`).catch(() => '')).trim().split('\n').pop() ?? ''
        $.ui.toast(`Octo did not start: ${last.replace(/^\S+ \S+ \S+ /, '')}`, { timeoutMs: 15000 })
      })
    }

    togglePet = async () => {
      if (await petAlive()) {
        await $.fs.write(hidden, '')
        await $.process.run(['kill', await petPid()])
        return 'Octo tucked away. /pet wakes it.'
      }
      await $.process.run(['rm', '-f', hidden])
      await launch()
      return 'Octo is on your desktop.'
    }

    // Quick chat and Stop arrive as files from the pet.
    const poll = async () => {
      let entries
      try {
        entries = await $.fs.list(cmdDir)
      } catch {
        return
      }
      for (const f of entries) {
        if (!f.name.startsWith(id)) continue
        const path = `${cmdDir}/${f.name}`
        // claim by rename so a command runs once even if this module is loaded twice
        const claimed = `${path}.${Math.random().toString(36).slice(2)}`
        if ((await $.process.run(['mv', path, claimed])).exitCode !== 0) continue
        const text = await $.fs.read(claimed).catch(() => '')
        await $.process.run(['rm', '-f', claimed])
        let cmd: { prompt?: string; abort?: boolean }
        try {
          cmd = JSON.parse(text)
        } catch {
          continue
        }
        if (cmd.prompt) void $.prompt.submit({ text: cmd.prompt, asUser: true })
        if (cmd.abort && turnId) await $.turn.abort({ turnId })
      }
    }

    await $.command.register({ name: 'pet', description: 'Wake Octo, the desktop pet, or tuck it away' })
    await write()
    void syncRecord().then(write)
    if (!(await $.fs.exists(hidden))) void launch()
    $.clock.every(5000, async () => {
      beats += 1
      // the record is read each beat once found; before that, grep for it for two minutes, then once a minute
      if (recordPath || beats < 24 || beats % 12 === 0) await syncRecord()
      await write()
    })
    $.clock.every(1000, poll)

    return next(e)
  })

  on('command.run', { command: 'pet' }, async () => ({ text: await togglePet() }))

  on('turn.start', async ($, e, next) => {
    turnId = e.turnId
    await set('running', 'Thinking…')
    return next(e)
  })

  on('tool.call', async ($, e, next) => {
    if (e.agentId) return next(e)
    const ask = ASKS[e.tool]
    await set(ask ? 'needs-input' : 'running', ask ?? short(e.tool))
    const ran = await next(e)
    if (turnId) await set('running', 'Thinking…')
    return ran
  })

  on('tool.check', async ($, e, next) => {
    const verdict = await next(e)
    if (verdict.decision === 'ask') await set('needs-input', `${short(e.tool)} wants approval`)
    return verdict
  })

  on('turn.complete', async ($, e, next) => {
    if (e.agentId) return next(e)
    turnId = null
    if (e.reason === 'answer') await set('ready', `Done in ${Math.round(e.durationMs / 1000)}s`)
    else if (e.reason === 'aborted') await set('idle', 'Stopped')
    else await set('blocked', e.reason === 'refusal' ? 'Refused' : 'API error')
    return next(e)
  })

  on('session.end', async ($, e, next) => {
    if (e.reason !== 'clear') await set('gone')
    return next(e)
  })
}
