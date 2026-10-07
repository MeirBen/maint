# Maintenance

Two features with a shared Bash runtime: Ubuntu system maintenance and local AI service control.

## Commands

```bash
update-system
local-ai                 # Choose start, stop, or update from the menu
local-ai start           # Start Ollama/Open WebUI and open the chat
local-ai stop
local-ai update
```

Both commands also accept an outer `sudo`. Otherwise, administrator authentication happens in the terminal when needed. An initial `sudo` password prompt is normal; an already-root run does not authenticate again.

`update-system` automatically applies normal APT upgrades while respecting Ubuntu's phased rollout. Applying a full upgrade, overriding phasing, removing unused APT packages, installing a recommended driver, updating firmware, and restarting still require confirmation. A full upgrade that removes packages requires the exact word `APPLY`. Installed Flatpak/Snap applications are updated by the existing workflow; unused Flatpak runtimes and obsolete APT cache files are cleaned automatically.

`local-ai update` runs the existing Ollama, Phi model, and Open WebUI updater. Its service-state restoration and recovery behavior remain in the administrator-owned backend.

`local-ai start` opens the browser in your normal desktop session. When run through `sudo`, it prints the chat address instead of launching a browser as root.

The desktop shortcuts point to `System Maintenance.desktop` and `Local AI.desktop` in this folder. They set `SCRIPT_PAUSE_ON_EXIT=1` to keep the terminal open after completion or failure. CLI runs exit without a final Enter prompt. Interrupting or terminating a run also skips this pause. Password requests, menus, and safety confirmations are independent of that setting.

## Layout

- `update-system.sh`: package checks, upgrade simulations, firmware/driver checks, cleanup, and reboot confirmation.
- `local-ai.sh`: action selection and calls to the existing administrator-owned AI service helper.
- `lib/common.sh`: log setup, locking, administrator commands, confirmations, error/exit handling, temporary-file cleanup, and summaries.
- `icons/`: desktop icons.
- `logs/update-system.log` and `logs/local-ai.log`: the latest run of each feature.
- `tests/test_toolkit.py`: isolated regression checks using Python's standard library.

Each log uses `[timestamp] [level] message` for toolkit messages and retains command output as emitted. Terminal messages use colors unless `NO_COLOR` has a nonempty value; saved toolkit messages contain no color escapes. Warnings count once; explanatory notes do not increase the count.

A run locks its own log before overwriting it. Another run of the same feature waits up to 180 seconds; the two different features have separate logs and locks. Logs remain writable by the toolkit's owner after a `sudo` run. Temporary simulation files and log locks are released on exit, before the desktop pause. A forced kill or power loss can prevent cleanup.

The local AI backend remains in `/usr/local/sbin/local-ai-service-control` and `/usr/local/libexec/local-ai-update.py`. It owns service operations, downloads, and update recovery; this refactor does not move privileged code into the shared runtime.

## Installed paths

The toolkit lives at `~/Maintenance`. The commands `/usr/local/bin/update-system` and `/usr/local/bin/local-ai` are small wrappers that execute the scripts here. Desktop entries are symbolic links to the two `.desktop` files in this folder.

Keep the scripts and `lib/common.sh` together. If the folder is renamed or moved again, update both CLI wrappers, both desktop files' `Exec` and `Icon` paths, and the desktop symbolic links. The scripts calculate their own log paths from their location. The existing Git history, icons, and editor settings stay with the folder.

These CLI wrappers and the administrator-owned AI backend are installed outside this repository. Copying this repository alone to another machine does not install those components or configure Ollama/Open WebUI.

## Verification

From this directory:

```bash
bash -n lib/common.sh
bash -n update-system.sh
bash -n local-ai.sh
python3 -B -m unittest discover -s tests -p 'test_*.py'
```

The tests use temporary copies, simulated privilege modes, fake administrator/service commands, and real terminal/locking checks. They do not install updates, reboot, or change services. Existing update decisions and simulations stay in `update-system.sh`; do not use a real maintenance run as a unit test.

Checks cover log formatting and warning counts, stdout/stderr capture, exit-status preservation, root/normal-user dispatch, menu and argument handling, concurrent-run locking, temporary-file cleanup, desktop pauses, interruption, exact full-upgrade approval, and reboot confirmation. An isolated real root-to-user check also verified log ownership during this refactor.

Validated on the installed Ubuntu 26.04.1 LTS system with Bash 5.3, sudo-rs 0.2.13, and ShellCheck 0.11. If ShellCheck is available, the additional lint command is:

```bash
shellcheck -x -P SCRIPTDIR lib/common.sh update-system.sh local-ai.sh
```

Runtime dependencies are the existing Ubuntu tools: Bash, util-linux `flock`, GNU core utilities, `sudo` for non-root actions, and the commands required by each feature. Python 3 is needed only for the tests and the existing local AI backend. No new package installation is required.

The runtime follows the installed Bash/Ubuntu behavior documented in the [Bash reference manual](https://www.gnu.org/software/bash/manual/bash.html) and [Ubuntu's flock manual](https://manpages.ubuntu.com/manpages/resolute/man2/flock.2.html).
