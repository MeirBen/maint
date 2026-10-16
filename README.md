# Maintenance

One command and one desktop launcher for Ubuntu maintenance and the local AI stack.

## Usage

```bash
maintenance                    # Menu of every action; returns to the menu after each one
maintenance local-ai           # Menu of one module's actions
maintenance local-ai start     # Run one action and exit
maintenance help               # List every command
maintenance list               # Every action as tab-separated MODULE, ACTION, TITLE, DESCRIPTION
```

| Command | Action |
| --- | --- |
| `maintenance system update` | Update and clean up Ubuntu: APT, drivers, firmware, Flatpak, Snap |
| `maintenance local-ai start` | Start Open WebUI + Ollama and open the chat |
| `maintenance local-ai stop` | Stop Open WebUI + Ollama |
| `maintenance local-ai update` | Update Ollama, the Phi model, and Open WebUI |
| `maintenance local-ai status` | Show Ollama, Docker, and Open WebUI status |

- Actions ask for your password when needed. Running with `sudo` also works; `sudo maintenance local-ai start` prints the chat URL instead of opening the browser.
- System update installs normal APT, Flatpak, and Snap updates automatically and respects APT phased updates. Phasing overrides, full upgrades, package removals, driver and firmware installs, and rebooting ask first; full upgrades that remove packages require typing `APPLY`.
- Status only reads service state and never starts services. It reports `UNKNOWN` when Docker is stopped or a query fails, and shows container health only while Open WebUI is running.
- Ctrl+C, closing the terminal, or `SIGTERM` stops the running action, cleans up, and exits the menu.

## Install and uninstall

```bash
./install.sh      # Links /usr/local/bin/maintenance and creates the Maintenance desktop launcher
./uninstall.sh    # Removes both
```

Run them as your own user; they ask for sudo only to change `/usr/local/bin`. Re-run `install.sh` after moving this folder. Uninstalling keeps `logs/`; delete this folder to remove everything.

Local AI actions call `/usr/local/sbin/local-ai-service-control` and `/usr/local/libexec/local-ai-update.py`, which are installed separately from this repository.

## Adding a module

Drop a file such as `modules/disk.sh` into `modules/`. Its name is the module name, and it only defines variables and functions:

```bash
# shellcheck shell=bash disable=SC2034 # MODULE_TITLE and MODULE_ACTIONS are read by maintenance.sh.
# Disk: filesystem upkeep.

MODULE_TITLE='Disk'
MODULE_ACTIONS=(
    'trim|Trim mounted SSD filesystems'
)

action_trim() {
    require_sudo
    run_root fstrim --all --verbose
    show_completion_summary
}
```

Each `name|description` entry needs an `action_<name>` function. The menu, `help`, and `maintenance disk trim` pick it up automatically; a module that fails to load is skipped with a message. Actions use the helpers in `lib/common.sh`: `info`, `success`, `warn_condition`, `warn_note`, `error`, `run`, `run_root`, `as_root`, `require_sudo`, `require_commands`, `confirm`, `confirm_phrase`, `create_temp_dir`, and `show_completion_summary`. Any failing command stops the action and is logged with its call chain. A running action shares its namespace with `maintenance.sh` and `lib/common.sh`, so modules must not redefine their functions (such as `main`, `usage`, `run_action`, or `info`).

## Front ends

The terminal menu is one front end. Another, such as a desktop UI, can drive the same command line:

- Discover actions with `maintenance list`, run one with `maintenance MODULE ACTION`, and read its exit code: `0` success, `129`/`130`/`143` interrupted, anything else a failure (a command that is not in the list exits with `2`).
- Output lines read `[YYYY-MM-DD HH:MM:SS] [LEVEL] message` (`INFO`, `OK`, `WARN`, `NOTE`, `SUMMARY`, `ERROR`), uncolored when output is not a terminal, interleaved with the output of commands the action runs.
- Without a terminal, every confirmation answers No, so a full upgrade, driver or firmware install, or reboot is skipped. A front end that approves them must provide its own prompt through `confirm` and `confirm_phrase` in `lib/common.sh`.
- Administrator access goes only through `require_sudo`, `as_root`, and `run_root` in `lib/common.sh`; a front end without a terminal needs a graphical sudo helper there, such as `SUDO_ASKPASS` or pkexec.

## Files

- `maintenance.sh` — command line, menu, and module registry.
- `lib/common.sh` — logging, locking, privileges, prompts, and cleanup for each action run.
- `modules/` — one file per feature area.
- `install.sh`, `uninstall.sh`, `icons/` — command link and desktop launcher.
- `tests/test_toolkit.py` — isolated regression tests.

## Logs

Each module writes to `logs/<module>/YYYY-MM-DD.log`, keeping today and the previous 89 days; `logs/<module>.log` links to today's file. Every run starts with a `=====` header naming the action, user, and process ID, and failures or interruptions are logged with their cause. Only one run of each module proceeds at a time; another waits up to 180 seconds.

## Checks

From the repository root:

```bash
for file in maintenance.sh lib/common.sh modules/*.sh install.sh uninstall.sh; do bash -n "$file"; done
python3 -B -m unittest discover -s tests -p 'test_*.py'
```

Tests use temporary files and fake system commands; they do not install updates or change services. Lint, if ShellCheck is installed (expected output: none):

```bash
shellcheck -x -P SCRIPTDIR maintenance.sh lib/common.sh modules/*.sh install.sh uninstall.sh
```
