# Tools

Generated from the tool catalogue (`AutonomousTestingAgent tool list --markdown`). Do not edit by hand.

## device_observe (read-only)

Look at the device without changing it. Commands:
- list_targets(?only): List the simulators and devices idb can reach
- describe_target: Describe the target: name, OS, state
- describe_screen(?filter): List what is on screen: labels, identifiers, types and positions of the elements. Start here, then act by label.
- read_screen(?mode, ?query, ?limit): The screen as a short list: controls with #numbers and positions, then readable text. After an action it returns only what changed. Prefer this to describe_screen.
- look(question): Look at the actual screenshot and answer a question about it in words. Slower and costlier than read_screen: use it only when the element list cannot tell you (an icon without a label, an image, a chart, a web page).
- find(text, ?role): Find elements by text, including ones scrolled out of view, with their #numbers and positions
- describe_point(x, y): Describe the element at a point on screen
- wait_for(text, ?until, ?timeout): Wait until some text is on screen (or gone), then return: use after an action that loads something, instead of reading again and again. Native controls only, not text inside a web page
- read_element(?label, ?identifier, ?handle): One element's state: its value (a switch reads 0 or 1), whether it is enabled, selected and on screen. Use it to check a toggle, a field or a selection
- screenshot: Take a screenshot; the file path is returned
- list_apps(?filter): List the installed apps with their bundle ids and whether they are running; pass filter to keep the answer short
- read_log(?seconds, ?process, ?lines): Read the recent device log (simulator)
- crash_list(?bundle_id): List crash reports
- crash_show(name): Show one crash report
- get_setting(name, ?domain): Read a device preference
- list_notifications(bundle_id): List an app's notifications
- file_list(bundle_id, path): List a folder inside an app's container
- file_read(bundle_id, path): Read a text file inside an app's container
- file_pull(bundle_id, path): Copy a file from an app's container to this Mac (under .runs/device)

| Argument | Required | What |
|---|---|---|
| `bundle_id` | no | Only this app's |
| `command` | yes | Which command to run |
| `confirm` | no | Only for a destructive command: true after the person has agreed to it |
| `domain` | no | Preference domain |
| `filter` | no | Only elements that can be tapped |
| `handle` | no | The #number from read_screen |
| `identifier` | no | Accessibility identifier |
| `label` | no | Visible label of the element |
| `limit` | no | Most controls to list, default 40 |
| `lines` | no | Most recent lines to return, default 80 |
| `mode` | no | auto (default): changes since the last read when the screen is the same, else everything. state: the changes, a line, then the whole screen |
| `name` | no | Report name from crash_list |
| `only` | no | Only this kind |
| `path` | no | Folder, relative to the container, for example Documents |
| `process` | no | Only this process |
| `query` | no | Only elements whose text, id or role contains this |
| `question` | no | What to find out, for example “which icon is the cart?” or “is there a red badge on the Inbox tab?” |
| `role` | no | Only this kind of element, for example button |
| `seconds` | no | How far back, default 30 |
| `target` | no | Optional: the id of a simulator or device from list_targets; default the booted simulator |
| `text` | no | Text to look for in labels, ids and values |
| `timeout` | no | Seconds to wait, default 10 |
| `until` | no | Default appears |
| `x` | no | X in points |
| `y` | no | Y in points |

## device_input

Touch, type and press buttons. Commands:
- tap(?label, ?identifier, ?handle, ?x, ?y): Tap an element by label or identifier, or a point
- double_tap(?label, ?identifier, ?handle, ?x, ?y): Double-tap an element or a point
- long_press(?label, ?identifier, ?handle, ?x, ?y, ?seconds): Press and hold an element or a point
- swipe(x1, y1, x2, y2, ?seconds): Swipe from one point to another
- scroll_to(text, ?direction, ?max_scrolls, ?within): Scroll until some text is on screen, then stop: for a control that is further down or across. Fails after max_scrolls
- scroll(direction, ?within): Scroll the screen: 'down' shows content further down
- pinch(x, y, scale): Pinch at a point: scale above 1 zooms in, below 1 zooms out
- type_text(text): Type text into the focused field
- press_key(key): Press a key
- press_button(button): Press a hardware button

| Argument | Required | What |
|---|---|---|
| `button` | no | Button |
| `command` | yes | Which command to run |
| `confirm` | no | Only for a destructive command: true after the person has agreed to it |
| `direction` | no | Default down |
| `handle` | no | The #number of an element from read_screen or find, for example #4 |
| `identifier` | no | Accessibility identifier of the element |
| `key` | no | Key |
| `label` | no | Visible label or accessibility label of the element |
| `max_scrolls` | no | Default 8 |
| `scale` | no | Scale |
| `seconds` | no | Hold time, default 1 |
| `target` | no | Optional: the id of a simulator or device from list_targets; default the booted simulator |
| `text` | no | Text, label or identifier to bring into view |
| `within` | no | Label of an element to scroll along, for a row that scrolls on its own (a chips or tabs row) |
| `x` | no | X in screen points (with y) |
| `x1` | no | Start X |
| `x2` | no | End X |
| `y` | no | Y in screen points (with x) |
| `y1` | no | Start Y |
| `y2` | no | End Y |

## device_app

Open links, and launch, stop, install or uninstall apps. Commands:
- open_url(url): Open a URL or deep link on the device
- launch_app(bundle_id): Launch an app, or bring it to the front if it is running
- terminate_app(bundle_id): Stop a running app
- install_app(path): Install an .app or .ipa from this Mac (inside the project or repository)
- uninstall_app(bundle_id): Uninstall an app and delete its data [destructive: needs confirm=true]

| Argument | Required | What |
|---|---|---|
| `bundle_id` | no | Bundle id of the app, for example com.apple.mobilesafari |
| `command` | yes | Which command to run |
| `confirm` | no | Only for a destructive command: true after the person has agreed to it |
| `path` | no | Path to the .app or .ipa |
| `target` | no | Optional: the id of a simulator or device from list_targets; default the booted simulator |
| `url` | no | http(s) or an app's own scheme; never file: |

## device_environment

Set location, permissions, notifications, appearance, photos and contacts. Commands:
- set_location(latitude, longitude): Set the device location
- approve_permission(bundle_id, permission): Grant a permission to an app without a dialog
- revoke_permission(bundle_id, permission): Revoke a permission from an app
- send_notification(bundle_id, payload): Deliver a push notification payload to an app
- set_appearance(mode): Switch between light and dark appearance
- set_setting(name, value, ?domain): Write a device preference
- add_media(path): Add a photo or video from this Mac to the device
- update_contacts(path): Replace the contacts with a .vcf or database file from this Mac
- simulate_memory_warning: Send the foreground app a memory warning
- clear_keychain: Erase the keychain [destructive: needs confirm=true]
- clear_photos: Delete every photo and video [destructive: needs confirm=true]
- clear_contacts: Delete every contact [destructive: needs confirm=true]

| Argument | Required | What |
|---|---|---|
| `bundle_id` | no | Bundle id of the app, for example com.apple.mobilesafari |
| `command` | yes | Which command to run |
| `confirm` | no | Only for a destructive command: true after the person has agreed to it |
| `domain` | no | Preference domain |
| `latitude` | no | Latitude |
| `longitude` | no | Longitude |
| `mode` | no | Appearance |
| `name` | no | Preference name |
| `path` | no | Path to the image or video |
| `payload` | no | JSON payload, for example {"aps":{"alert":"Hello"}} |
| `permission` | no | Permission |
| `target` | no | Optional: the id of a simulator or device from list_targets; default the booted simulator |
| `value` | no | Value |

## device_files

Read and write files inside an app's container. Commands:
- file_push(bundle_id, source, path): Copy a file from this Mac into an app's container
- file_mkdir(bundle_id, path): Create a folder inside an app's container
- file_move(bundle_id, from, to): Move or rename a file inside an app's container
- file_remove(bundle_id, path): Delete a file or folder inside an app's container [destructive: needs confirm=true]

| Argument | Required | What |
|---|---|---|
| `bundle_id` | no | Bundle id of the app, for example com.apple.mobilesafari |
| `command` | yes | Which command to run |
| `confirm` | no | Only for a destructive command: true after the person has agreed to it |
| `from` | no | From |
| `path` | no | Destination folder in the container |
| `source` | no | File on this Mac |
| `target` | no | Optional: the id of a simulator or device from list_targets; default the booted simulator |
| `to` | no | To |

## device_system

Boot or shut down simulators, or erase one. Commands:
- boot: Boot the simulator
- shutdown: Shut the simulator down
- crash_delete(name): Delete a crash report [destructive: needs confirm=true]
- erase_target: Erase the simulator: all apps and data (it must be shut down first) [destructive: needs confirm=true]

| Argument | Required | What |
|---|---|---|
| `command` | yes | Which command to run |
| `confirm` | no | Only for a destructive command: true after the person has agreed to it |
| `name` | no | Report name |
| `target` | no | Optional: the id of a simulator or device from list_targets; default the booted simulator |

## device_sequence

Do several device commands in one call and get the screen's changes back: saves round trips. Each step is {command, …its arguments}, from device_input, device_app, device_environment or device_observe; at most 12; it stops at the first failure. A destructive command is refused here: call it on its own.

| Argument | Required | What |
|---|---|---|
| `settle_ms` | no | Pause after each step, default 300 |
| `steps` | yes | The commands, in order, each with its own arguments |

## list_device_commands (read-only)

Every device command with its tool, risk and arguments.

## list_cases (read-only)

The test cases of this project: those in TestCases/ and those fetched earlier from AIO (key, title, step count).

## read_case (read-only)

One test case with its steps: action, test data and expected result.

| Argument | Required | What |
|---|---|---|
| `key` | yes | The case key, for example SAFARI-1 |

## write_case

Create a test case in TestCases/. A key that already exists is refused unless replace=true and the case was written by an agent. Passwords are never written here: use the placeholder [CREDENTIALS].

| Argument | Required | What |
|---|---|---|
| `key` | yes | New case key, for example LOGIN-2 |
| `replace` | no | Replace an existing agent-written case |
| `steps` | yes | 1 to 25 steps, in order |
| `title` | yes | One line saying what the case checks |

## generate_cases

Draft test cases from a requirement: Gherkin (Feature/Scenario/Given/When/Then) or a story with acceptance criteria as a list. Give the text, or a file inside the project. Without write=true it only previews. Saved drafts get keys PREFIX-1, PREFIX-2… and source agent; refine them with read_case and write_case replace=true before running. For a code change use plan_tests instead.

| Argument | Required | What |
|---|---|---|
| `file` | no | A markdown or text file inside the project, instead of text |
| `key_prefix` | no | Prefix for the new keys, default GEN |
| `text` | no | The requirement text |
| `write` | no | Save the drafts in TestCases/ (default: preview only) |

## run_case

Run a test case on the booted simulator and wait for the result (minutes). The runner plans and judges with its own model, so DEEPSEEK_API_KEY (or Gemini) must be set where the server runs; without a key use the device tools directly. The password comes from TEST_USER_PASSWORD in the server's environment, never from here. A destructive step is refused unless allow_destructive=true. Returns the outcome and each step's result.

| Argument | Required | What |
|---|---|---|
| `allow_destructive` | no | Allow steps that delete or log out; only after the person agreed |
| `bundle_id` | no | Bundle id of the app under test; default the case's own app |
| `clear_guidance` | no | Forget the guidance saved for this case before running |
| `end_step` | no | Last step to run |
| `guidance` | no | Plain-words instructions for the run, saved for this case until cleared. For a name that already exists: "use Test2 instead of Test1". Other words become notes for the planner and judge |
| `key` | yes | Case key |
| `start_step` | no | First step to run |
| `username` | no | Username for the login step; default TEST_USER_USERNAME |

## list_runs (read-only)

Recent case runs, newest first: id, case, outcome, when and how long.

| Argument | Required | What |
|---|---|---|
| `limit` | no | How many, default 10 |

## get_report (read-only)

One run's report: outcome and every step with its result and detail. Use the id from list_runs or run_case. format=junit returns JUnit XML for a CI system; with no run_id it covers the latest run of each case.

| Argument | Required | What |
|---|---|---|
| `format` | no | text (default) or junit |
| `run_id` | no | The run id; optional with format=junit |

## plan_tests (read-only)

Plan tests for a code change by static analysis (touches no device): risk, impact, gaps and drafted specs, as JSON.

| Argument | Required | What |
|---|---|---|
| `base` | no | Git ref to compare against, default the repository's default |
| `files` | no | Comma-separated files to plan for instead of a git diff |

