# Architecture

`orca.koplugin` is a KOReader plugin. `main.lua` only wires modules together and
follows KOReader's lifecycle; everything else lives under `orca/`:

| Folder | What | Depends on |
| --- | --- | --- |
| `orca/core/` | `util` (pure helpers), `settings` (keys and defaults), `jobs` (coroutine queue), `connection` (client, reconnect hooks, stream routing, keep-alive), `shell` (quoting for desktop commands) | nothing from KOReader's UI |
| `orca/api/` | Orca RPC calls returning plain data: `api.git.status(c, wt)` | the client |
| `orca/render/` | pure text helpers: `ansi` (escape codes, prompt excerpt, choices), `diff` | nothing |
| `orca/ui/` | `style` (design tokens), `kit` (rows, headers, title bar, buttons), `window` (the screen stack), `dialog` (cards: confirm, sheet, alert, toast), `text` (keyboard input, long text, open as book) | KOReader widgets |
| `orca/features/` | one module per area: `home`, `workspace`, `session`, `create`, `git`, `files`, `conversations`, `notify`, `accounts`, `automations`, `sleepscreen`, `passage`, `menu` | `app` |
| `orcaclient/` | WebSocket + NaCl transport for Orca's mobile protocol | LuaSocket, libtweetnacl |

## The app context

Every feature is a class built with `Feature.new(app)` and stored on the app
(`app.git`, `app.notify`, …), so features open each other's screens by name
(`self.app.git:open(wt)`). `app` carries:

- `app.settings`: `get(key)` (with defaults from `core/settings.lua`), `set`, `flip`, `isPaired`, `clientId`.
- `app:request{ busy?, once?, background?, run = function(c) … end, done = function(result) … end, on_error? }`:
  runs `run` in a job with a connected client, shows errors (with Retry unless `once`).
  Use `once = true` for anything that changes state (commit, push, merge, send keys):
  it won't be retried after a reconnect. `app:run(job)` is the raw form (`done(result, err)`).
- `app.nav`: `push(spec)`, `replace(spec)`, `pop()`, `close()`, `top()`; `push`/`replace`
  return a page handle with `page:set(spec)` (ignored once the user left that screen) and `page:isShown()`.
- `app.dialog`: `card`, `confirm`, `sheet`, `alert`, `toast`, `close`, `isShown`.
- `app.text`: `ask` (keyboard), `read` (long text), `book`; `app:openAsBook(name, text)`.
- `app.connection`: `stream(c, method, params, handler)`, `stopStream(c, id)`, `onConnect(key, fn)`, `keepAlive(jobs, key, on)`, `pump(jobs)`, `reset()`.
- `app:agent()`, `app:agentName()`, `app:explain(err)`, `app:fail(err, retry)`, `app:toast(text)`, `app.online(fn)`, `app.now()`.

## Screens

A screen is data; `ui/window.lua` draws it:

```lua
{
    title = "kindle", subtitle = "main",
    refresh = function() … end,          -- ↻ in the title bar
    add = function() … end,              -- + in the title bar
    sections = { { title = "Sessions", rows = { row, … } }, … },
    empty = "No sessions running here.", -- shown when there are no rows
    loading = "Loading sessions…",       -- shown instead of rows
    on_close = function() … end,
}
row = { glyph, title, subtitle, detail, bold, chevron, dim, mono, truncate_left,
        callback, hold_callback }
```

The usual load pattern: push a `loading` screen, then `page:set(spec)` when the
job finishes (see `features/home.lua`).

## Design rules

From Apple's HIG, adapted to grayscale e-ink (see `orca/ui/style.lua`):

- Hierarchy comes from size and weight, never color. Nothing outside the terminal is smaller than 16 px.
- Status is always a glyph plus a word: ● Needs you, ◐ Working, ○ Done. PR checks: ✓ ✕ … –.
- Rows that drill in end with ›; rows that act immediately don't.
- Buttons are verbs ("Merge", "Push", "Re-run checks"); never OK, Yes or No. A trailing … means more input follows.
  Every confirmation has Cancel. Destructive actions are confirmed; common, undoable ones aren't.
- Errors say what happened and what to do (`app:explain`). Empty screens say what's missing and the next step.
- Progress text names the action: "Pushing to origin…", not "Loading…".
- One popup at a time. Touch targets are at least 48 px.
- Labels use the agent's name (`app:agentName()`), not a hardcoded "Claude".

## Tests

`luajit tests/run.lua` runs every `tests/features/*_test.lua` on a PC.
`tests/harness.lua` builds the real app (features, jobs, settings) with a fake
Orca (`H.results[method]`) and fake nav/dialog/text, then drives screens:
`t.tap("Git")`, `t.press("Merge")`, `t.answer("message")`, `t.lastCall("git.commit")`.
`tests/device/` holds scripts that run on the Kindle with KOReader's LuaJIT;
`tests/device/rpc_probe.lua` calls every RPC the screens use against the real desktop.
