---
name: autonomous-testing-agent
description: Operate an iOS simulator and run or write UI test cases with the Autonomous Testing Agent. Use when asked to try an app on the simulator, tap through a flow, check what is on screen, write a test case, run an existing case, or read a test run's report.
---

# Autonomous Testing Agent

Gives you eyes and hands on an iOS simulator (through idb) and a runner for plain-language test cases. You do the thinking; the tools do the touching.

## How to call it

Use whichever is available. The tools are the same.

- **MCP server** (`ata-mcp`): the tools appear in your tool list: `device_observe`, `device_input`, `run_case`, ...
- **Command line**: `AutonomousTestingAgent tool call <tool> '<json arguments>'` prints JSON (`isError`, `content`). `AutonomousTestingAgent tool list` shows the tools, `tool describe <tool>` one schema. Run it from the project folder or pass `--project-root=<dir>`.

Every tool, with its arguments, is in [references/tools.md](references/tools.md).

## Operating the simulator: observe, act, check

1. `device_observe` with `command: read_screen`. You get a short list: controls with `#numbers` and positions, then the readable text. Read it before acting.
2. Act with `device_input`: `tap` by `handle` (`#4`) or `label`, `type_text`, `swipe`, `scroll`, `press_key`. Prefer a handle or label to coordinates.
3. For a known run of actions (tap a field, type, press return) send them as one `device_sequence` call: it returns the screen's changes at the end and saves round trips. After something that loads, `device_observe` `wait_for` with the text you expect instead of reading again and again (it sees native controls only, not text inside a web page).
4. `read_screen` again. After an action it shows only what changed. That is your check; do not assume an action worked.
5. If the list cannot answer (an icon with no label, a picture, web page text), use `device_observe` `screenshot` and read it yourself, or `look` with a question (needs a Gemini key). The list first; it is cheaper.
6. Apps and settings: `device_app` (`launch_app`, `open_url`), `device_environment` (appearance, location, permissions). Use these instead of tapping through Settings.

Some system screens (Settings on recent simulators) and web page content return an empty or partial list. Take a `screenshot` and read the picture yourself (it comes back as an image and a file path, with a line saying how to turn a point on the picture into a tap: x and y times the stated factors), or use `look` if the server has a Gemini key. Or change the setting with `device_environment`.

## Test cases

- `list_cases`, `read_case` to see what exists. A case is steps of *action*, optional *data*, and *expected* result, in plain words.
- `generate_cases` drafts cases from a written requirement (Gherkin, or a story with acceptance criteria); preview first, then `write=true`. The drafts are placeholders to refine with the real labels from the screen before running.
- `write_case` creates one. Quote exact visible labels in `expected`. Never put a password in a case; write `[CREDENTIALS]` where one is typed.
- `run_case` runs a case on the booted simulator and waits (minutes). The runner plans and judges with its own model, so it needs `DEEPSEEK_API_KEY` (or a Gemini key) where it runs; with no key, do the steps yourself with the device tools. It returns the outcome and each step. Use `start_step` and `end_step` to run part of a case. Then `get_report` with the run id for detail, `list_runs` for history.
- Logins need `TEST_USER_USERNAME` and `TEST_USER_PASSWORD` set in the environment the server or command runs in, or in the project's git-ignored `.env`. Do not pass passwords as tool arguments, and do not ask the user to paste one into chat.
- `device_observe` `list_apps` takes `filter` to find a bundle id without listing every app.
- `plan_tests` plans tests for a code change by static analysis (no device).

## Safety

- A destructive command (uninstall, erase, clear data or photos) is refused until you call again with `confirm: true`. Only do that after the user agreed to that specific action.
- `run_case` refuses destructive steps unless `allow_destructive: true`; same rule.
- Reading and tapping are allowed. Tell the user what you changed on the device.
- The server reads only this project's `TestCases/` and `.runs/`. It cannot run shell commands or read other files.

## When a run needs the user

A run holds when only a person can go on: a login, a verification code, a captcha, an approval on another phone, a Face ID or passcode prompt, or a step marked manual. `run_case` then reports "WAITING FOR THE USER: …" (with its timeout, ten minutes unless `ATA_USER_WAIT_SECONDS` says otherwise). Tell the user at once what to do on the simulator; the run carries on by itself when the screen moves on, and stops with a reason if nobody acts in time. Do not try to type a code or solve a captcha yourself.

## Test data that clashes

A run can hit data that is already there ("Test1 already exists"). Give `run_case` a `guidance` such as `use Test2 instead of Test1`: it changes the test data and the expected results from then on, any other words become notes for the planner and judge, and it is saved for that case until `clear_guidance` is passed. With no guidance, the runner suggests the next free value (Test2), takes it, and says so in the result; tell the user which value it used. In the app and the terminal the person can say the same thing while a run is going.

## When a call fails

An `isError` result says why in words (no simulator booted, a bad argument, idb missing). Fix that and retry; do not retry blindly. No booted simulator: `device_observe` `list_targets` shows them, then `device_system` `boot` with the target id.
