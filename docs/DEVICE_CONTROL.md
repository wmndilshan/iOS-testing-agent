# Device control for the agents

The agents can look at and drive a simulator (and, by design, a connected device) with a typed set of idb commands. It is a lane of its own,
separate from the trusted spine that runs test cases (`ARCHITECTURE.md`, "Device control lane"): the spine stays element-targeted and untouched.

## How a command travels

1. An agent (the **DeviceOperator**, or any agent given the tools) calls one of six grouped tools with a `command` and its arguments.
2. The agent process sends `{"t":"agent-device-request","id","command":{kind,arguments,target}}`. It never touches the device and never approves.
3. The app (`AgentChatState+Device.swift`) validates the command (`DeviceCommandValidator`), asks `DeviceControlPolicy` what is needed, shows the
   approval banner when it must ask, runs it through `DeviceControlling` (`IDBDeviceControl`, over `IDBClient`) and writes
   `{"t":"device-result","id","text"}` back. A refusal or failure arrives as text beginning `FAILED:`.

## Approval tiers

| Risk | Examples | Approval |
|---|---|---|
| `readOnly` | describe_screen, screenshot, list_apps, read_log, crash_list, file_list | none |
| `reversible` | tap, type_text, press_button, open_url, launch_app, set_location, approve_permission, set_appearance, add_media, file_push | asked once; "Allow for this chat" lifts it for the rest of that chat (in memory; a relaunch asks again) |
| `destructive` | uninstall_app, clear_keychain, clear_photos, clear_contacts, crash_delete, file_remove, erase_target | asked every time; never grantable for a chat |

## Commands

The single list is `DeviceCommandCatalog` (name, group, risk, target support, arguments, wording); the agent tools, the approval text and the tests all
read it. "Sim" means simulator only; the rest are meant to work on a real device too (idb supports it) but are verified on the simulator.

| Tool | Commands |
|---|---|
| `device_observe` | list_targets, describe_target, describe_screen, describe_point, screenshot, list_apps, read_log (Sim), crash_list, crash_show, get_setting (Sim), list_notifications (Sim), file_list, file_read, file_pull, crash_delete |
| `device_input` | tap / double_tap / long_press (by label, identifier or point), swipe, scroll, pinch (Sim), type_text, press_key, press_button |
| `device_app` | open_url, launch_app, terminate_app, install_app, uninstall_app |
| `device_environment` | set_location, approve_permission, revoke_permission, send_notification, set_appearance, set_setting, add_media, update_contacts, simulate_memory_warning (all Sim except add_media), clear_keychain, clear_photos, clear_contacts (Sim) |
| `device_files` | file_push, file_mkdir, file_move, file_remove |
| `device_system` | boot, shutdown, erase_target (Sim) |

`tap` by label looks at a fresh accessibility tree and needs exactly one match; several matches come back as a list of candidates instead of a guess.

## Safety rules

- Typed commands only: there is no argument that carries a command line, and `IDBClient` is the only code that starts `idb` or `simctl` (arrays, no shell).
- Host files (`install_app`, `add_media`, `file_push`, `update_contacts`) must exist inside the project or the chosen repository (symbolic links resolved) and are never
  secrets (`.env`, keys, provisioning profiles). Results (screenshots, pulled files) are written only under `.runs/device/`.
- Device paths stay inside an app's container: relative, no `..`. URLs may not use `file:`, `javascript:` or `data:`.
- Results are redacted and capped at 6,000 characters.
- `Tests/…/Architecture/DeviceControlLaneTests.swift` pins the structure (no process starts in the lane, no path into the spine, the agent target never names the executor).

## Trying it without a chat

Debug builds have `--device-run='{"kind":"list_apps","arguments":{}}'`, which runs one command on the booted simulator through the real lane and prints
the result. It skips the approval a chat would ask for: it is a developer's check, not the agents' path.
