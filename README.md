# Maintenance

One command and one desktop launcher for Ubuntu maintenance and the local AI stack.

## Usage

```bash
maintenance                    # Menu of every action; returns to the menu after each one
maintenance local-ai           # Menu of one module's actions
maintenance local-ai start     # Run one action and exit
maintenance help               # List every command
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

## Install

```bash
./install.sh
```

Run it as your own user; it asks for sudo only to link `/usr/local/bin/maintenance`. It also creates the trusted `Maintenance` launcher on the desktop. Re-run it after moving this folder.

Local AI actions call `/usr/local/sbin/local-ai-service-control` and `/usr/local/libexec/local-ai-update.py`, which are installed separately from this repository.

## Adding a module

Drop a file into `modules/`. Its name is the module name, and it only defines variables and functions:

```bash
# modules/disk.sh
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

## Files

- `maintenance.sh` — command line, menu, and module registry.
- `lib/common.sh` — logging, locking, privileges, prompts, and cleanup for each action run.
- `modules/` — one file per feature area.
- `install.sh`, `icons/` — command link and desktop launcher.
- `tests/test_toolkit.py` — isolated regression tests.

## Logs

Each module writes to `logs/<module>/YYYY-MM-DD.log`, keeping today and the previous 89 days; `logs/<module>.log` links to today's file. Every run starts with a `=====` header naming the action, user, and process ID, and failures or interruptions are logged with their cause. Only one run of each module proceeds at a time; another waits up to 180 seconds.

## Checks

From the repository root:

```bash
for file in maintenance.sh lib/common.sh modules/*.sh install.sh; do bash -n "$file"; done
python3 -B -m unittest discover -s tests -p 'test_*.py'
```

Tests use temporary files and fake system commands; they do not install updates or change services. Optional lint, if ShellCheck is installed:

```bash
shellcheck -x -P SCRIPTDIR maintenance.sh lib/common.sh modules/*.sh install.sh
```
