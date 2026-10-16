# Maintenance

`maint` is one command and one desktop launcher for Ubuntu maintenance and the local AI stack.

## Usage

```bash
maint                 # Menu of every action; returns to the menu after each one
maint ai              # Menu of one module's actions
maint ai start        # Run one action and exit
maint help            # Show every command
maint list            # Every action as tab-separated MODULE, ACTION, TITLE, DESCRIPTION
```

Press Tab to complete module and action names, for example `maint ai st<Tab>`.

| Command | Action |
| --- | --- |
| `maint sys update` | Update and clean up Ubuntu: APT, drivers, firmware, Flatpak, Snap |
| `maint ai start` | Start Open WebUI + Ollama and open the chat |
| `maint ai stop` | Stop Open WebUI + Ollama |
| `maint ai update` | Update Ollama, the Phi model, and Open WebUI |
| `maint ai status` | Show Ollama, Docker, and Open WebUI status |

- Actions ask for your password when needed. Running with `sudo` also works; `sudo maint ai start` prints the chat URL instead of opening the browser.
- `maint sys update` installs normal APT, Flatpak, and Snap updates automatically and respects APT phased updates. Phasing overrides, full upgrades, package removals, driver and firmware installs, and rebooting ask first; full upgrades that remove packages require typing `APPLY`.
- `maint ai status` only reads service state and never starts services. It reports `UNKNOWN` when Docker is stopped or a query fails, and shows container health only while Open WebUI is running.
- Ctrl+C, closing the terminal, or `SIGTERM` stops the running action, cleans up, and exits the menu.
- A mistyped module or action lists the valid choices.

## Install and uninstall

```bash
./install.sh      # Adds the maint command, Tab completion, and the Maintenance desktop launcher
./uninstall.sh    # Removes all three
```

Run them as your own user; they ask for sudo only to change `/usr/local/bin`. Open a new terminal after installing for Tab completion. Re-run `install.sh` after moving this folder. Uninstalling keeps `logs/`; delete this folder to remove everything.

Local AI actions call `/usr/local/sbin/local-ai-service-control` and `/usr/local/libexec/local-ai-update.py`, which are installed separately from this repository.

## Configure

- **Disable a module:** rename it so it no longer ends in `.sh`, for example `mv modules/ai.sh modules/ai.sh.off`. It disappears from the menu, `maint help`, `maint list`, and Tab completion at once; rename it back to enable it. To remove it for good, delete the file.
- **Module settings** sit in a `# Settings.` block at the top of each module: `MIN_ROOT_FREE_GIB` in `modules/sys.sh`; `SERVICE_CONTROL`, `DOCKER`, `CONTAINER`, and `CHAT_URL` in `modules/ai.sh`.
- **Shared settings** sit at the top of `lib/common.sh`: `LOG_RETENTION_DAYS` and `LOCK_WAIT_SECONDS`.
- **Menu text** is the `MODULE_TITLE` and the `MODULE_ACTIONS` descriptions of each module.

Changes apply on the next run; nothing needs reinstalling.

## Adding a module

Drop a file such as `modules/disk.sh` into `modules/`. Its name is the module name, and it only defines variables and functions:

```bash
# shellcheck shell=bash disable=SC2034 # MODULE_TITLE and MODULE_ACTIONS are read by maint.
# Disk: filesystem upkeep.

MODULE_TITLE='Disk'
MODULE_ACTIONS=(
    'trim|Trim mounted SSD filesystems'
)

action_trim() {
    require_sudo
    run_root fstrim --all --verbose
}
```

Each `name|description` entry needs an `action_<name>` function. The menu, `maint help`, `maint list`, Tab completion, and `maint disk trim` pick it up automatically; a module that fails to load is skipped with a message.

Each action runs in its own process, `lib/run.sh`, with only `lib/common.sh` and its own module loaded. Actions use these helpers and must not redefine them: `info`, `success`, `warn_condition`, `warn_note`, `error`, `run`, `run_root`, `as_root`, `require_sudo`, `require_commands`, `confirm`, `confirm_phrase`, `create_temp_dir`, and `show_completion_summary`. Any failing command stops the action and is logged with its call chain. After an action succeeds, its summary of warnings and duration is logged automatically; call `show_completion_summary` yourself only to log it earlier, as `modules/sys.sh` does before offering a reboot.

## Front ends

The terminal menu is one front end. Another, such as a desktop UI, can drive the same command:

- Discover actions with `maint list`, run one with `maint MODULE ACTION`, and read its exit code: `0` success, `129`/`130`/`143` interrupted, anything else a failure (a command that is not in the list exits with `2`).
- Output lines read `[YYYY-MM-DD HH:MM:SS] [LEVEL] message` (`INFO`, `OK`, `WARN`, `NOTE`, `SUMMARY`, `ERROR`), uncolored when output is not a terminal, interleaved with the output of commands the action runs.
- Without a terminal, every confirmation answers No, so a full upgrade, driver or firmware install, or reboot is skipped. A front end that approves them must provide its own prompt through `confirm` and `confirm_phrase` in `lib/common.sh`.
- Administrator access goes only through `require_sudo`, `as_root`, and `run_root` in `lib/common.sh`; a front end without a terminal needs a graphical sudo helper there, such as `SUDO_ASKPASS` or pkexec.

## Files

- `maint` — command line, menu, and module registry.
- `lib/run.sh` — runs one action in its own process.
- `lib/common.sh` — settings, logging, locking, privileges, prompts, and cleanup for each action run.
- `modules/` — one file per module: `sys.sh` (System) and `ai.sh` (Local AI).
- `completion.bash` — Tab completion, read from `maint list`.
- `install.sh`, `uninstall.sh`, `icons/` — command, completion, and desktop launcher setup.
- `tests/test_toolkit.py` — isolated regression tests.

## Logs

Each module writes to `logs/<module>/YYYY-MM-DD.log`, keeping `LOG_RETENTION_DAYS` days (90) including today; `logs/<module>.log` links to today's file. Every run starts with a `=====` header naming the action, user, and process ID, and failures or interruptions are logged with their cause. Only one run of each module proceeds at a time; another says it is waiting and waits up to `LOCK_WAIT_SECONDS` (180).

## Checks

From the repository root:

```bash
for file in maint lib/*.sh modules/*.sh completion.bash install.sh uninstall.sh; do bash -n "$file"; done
python3 -B -m unittest discover -s tests -p 'test_*.py'
```

Tests use temporary files and fake system commands; they do not install updates or change services. Lint, if ShellCheck is installed (expected output: none):

```bash
shellcheck -x -P SCRIPTDIR maint lib/*.sh modules/*.sh completion.bash install.sh uninstall.sh
```
