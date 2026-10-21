# Operate

The **Operate** section gives a task to a team of agents that drives the simulator the way a person would, then tells you what it found. You watch the plan, what each agent does, and the live screen, and you can pause, take over by clicking the screen, and resume.

## How it works

```
Task ─► Orchestrator (plans; plans again after a failure, with the strong model)
          ├─ Perception lead ─ Reader (a function), Inspector
          ├─ Action lead ─ Navigator, Configurator
          └─ Quality lead ─ Verifier
Per goal (edges are code, not model calls):
  observe ─► navigate | configure | inspect | verify ─► observe ─► verify ─► next | retry (≤3) | re-plan | report
```

- The agent process (`AutonomousTestingAgent --operate --events --task=… [--repo=…]`) runs the graph. It never touches the device: every command is a request the app validates, asks about where needed, and runs (`DeviceRequestHandler`, the same one the chat uses).
- **The screen is read as a short accessibility digest** (controls with `#numbers` and positions, then text; after an action only what changed). `look(question)` sends one compressed screenshot to Gemini and returns text; only the Inspector and Verifier have it, and the digest is tried first. Screens that expose no accessibility tree (some system screens, such as Settings in the simulator) can only be read with `look`.
- **No repository.** Operate works from the screen alone and never reads the repository set in the Agent section; there is no code lead. (An architecture test pins this.)
- **The device's own answer counts.** A command that changes the device reports back (for example "The device appearance is now dark"), and the Verifier is shown that as evidence, because a web page can stay light in dark mode.
- **Approvals:** read-only commands run; reversible ones (tap, type, open a link) run when "Let the agents … without asking" is on for the task, otherwise they ask; destructive ones always ask.
- **Goal cards:** each goal of the plan is a card with what was done in words, the check's verdict and the reasoning behind a disclosure; the active goal opens by itself. Earlier tasks are listed in the sidebar while Operate is selected (Chats belong to Agent).
- **Pause / take over / resume:** Pause holds the graph between nodes and tool calls and keeps everything it knows. While paused (or idle) a click on the live screen is your own tap: validated and run, never asked about, shown as a green ring and recorded as a human step. Resume re-reads the screen first. When the Verifier meets something only you can do (a login, a code) the graph pauses itself and shows why.
- **Highlight:** a ring shows where each agent tap landed.
- **Save as test case** turns what was done into plain-language steps in the Tests section: one step per passed goal (the goal as the step, the actions as data, the check as the expected result), taps named by label and never by coordinates, then your own taps as steps of their own.

## How the team spends its time

- Each part has only the tools it needs: the Orchestrator plans, the Navigator taps and types (and can `wait_for` something to load), the Configurator changes the device, the Inspector reads, the Verifier checks. Routing between them is code, not a model call.
- **Reads are skipped when they would repeat.** A screen read after an action stays valid until the next action, a pause or a person's turn, so a goal does not read it again.
- **A read after an action waits for the screen to settle** (two reads in a row agree, at most three more times) so a sheet still sliding up or a page still loading is not judged half-way.
- **The result shows where the time went** (`Time by agent`), from the graph's node timings, so a slow task can be traced to its part.
- Measured on the same dark-mode task: 68 s, then 38 s, then about 24 s with 14 model calls.

## Limits worth knowing

- DeepSeek tool-calling is weaker on unlabeled UIs; `look` covers those, at a few seconds per call.
- `look` sends a screenshot to Gemini, only when an agent asks for it.

## Developer flags (debug builds)

`--tab=Operate`, `--operate-task="…" [--exit]` (logs `OPERATE …` lines to stdout).
