# maint

`maint` is a modular maintenance framework: one command, one terminal menu, and one desktop launcher for whatever modules sit in `modules/`. The framework provides discovery, the menu and command line, Tab completion, per-module logs, locking, administrator access, prompts, and cleanup; a module only declares its actions. The `sys` and `docker` modules ship with it; see [Example modules](#example-modules).

## Usage

```bash
maint                         # Menu of every action; returns after each one
maint MODULE                  # Menu of one module's actions
maint MODULE ACTION           # Run one action and exit
maint --help                  # General help (-h also works)
maint docker --help           # Help for one module
maint docker update --help    # Help for one action
maint help docker update      # Equivalent command-specific help
maint --version               # Program version (-V also works)
maint --no-color docker list  # Run without maint's terminal colors
maint list                    # Tab-separated MODULE, ACTION, TITLE, DESCRIPTION
```

Options can appear before or after the module and action. `--` ends option parsing; for example, `maint -- docker list`. Unknown options, extra arguments, and unknown commands report an error on stderr and exit with status `2`. As in GNU tools, `--version` ignores every option and argument after it, and an earlier `--help` wins over it; it does not load modules or initialize the action runtime. Help never runs an action: general help lists every action, the exit statuses, and `NO_COLOR`, while module and action help show only their own scope.

Press Tab to complete options, module names, action names, and `help` targets. Existing `maint help`, menu navigation, action commands, and the machine-readable `maint list` format remain supported.

Menus wrap to the terminal width. Docker inventory uses aligned columns when they fit and labeled entries in narrower windows; logs and redirected Docker output keep the full tab-separated values. Set `NO_COLOR=1` for plain text.

- Actions ask for your password when they need administrator access. Running with `sudo` also works.
- Ctrl+C, closing the terminal, or `SIGTERM` stops the running action, cleans up, and exits the menu.
- A mistyped module or action lists the valid choices.

## Install and uninstall

```bash
./install.sh      # Adds the maint command, Tab completion, and the Maintenance desktop launcher
./uninstall.sh    # Removes all three
```

Run them as your own user; they ask for sudo only to change `/usr/local/bin`. Open a new terminal after installing for Tab completion. Re-run `install.sh` after moving this folder. Uninstalling keeps `logs/`; delete this folder to remove everything.

## Configure

- **Disable a module:** rename it so it no longer ends in `.sh`, for example `mv modules/MODULE.sh modules/MODULE.sh.off`. It disappears from the menu, `maint help`, `maint list`, and Tab completion at once; rename it back to enable it. To remove it for good, delete the file.
- **Module settings** sit in a `# Settings.` block at the top of each module.
- **Shared settings** sit at the top of `lib/common.sh`: `LOG_RETENTION_DAYS` and `LOCK_WAIT_SECONDS`.
- **Menu text** is the `MODULE_TITLE` and the `MODULE_ACTIONS` descriptions of each module.
- **Release version** is defined once by `MAINT_VERSION` in `maint`; update it when preparing a release.

Changes apply on the next run; nothing needs reinstalling.

## Writing a module

Drop a file such as `modules/disk.sh` into `modules/`. Its name is the module name (`help`, `list`, and the CLI option names are reserved), and it only defines variables and functions:

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

Each action runs in its own process, `lib/run.sh`, with only `lib/common.sh` and its own module loaded. Actions use these helpers: `info`, `success`, `warn_condition`, `warn_note`, `error`, `print_and_log`, `run`, `run_root`, `as_root`, `require_sudo`, `require_commands`, `confirm`, `confirm_phrase`, `create_temp_dir`, and `show_completion_summary`. They may also read `LOG_FILE`, to append raw command output, and `TMP_DIR`, the folder `create_temp_dir` makes and the run removes. A module must not redefine anything `lib/common.sh` defines. Actions run under `set -Eeuo pipefail`, so a failing command, a failing pipeline stage, or an unset variable stops the action. A failing command is logged with its call chain; any other failure is logged with its exit code. After an action succeeds, its summary of warnings and duration is logged automatically; call `show_completion_summary` yourself only to log it earlier, as the `sys` example does before offering a reboot.

## Example modules

`sys` is an ordinary module, written the same way as `disk.sh` above. Use it as a template for your own, or disable it; the framework does not depend on it.

### `sys`: one long, guarded action

| Command | Action |
| --- | --- |
| `maint sys update` | Update and clean up Ubuntu: APT, drivers, firmware, Flatpak, Snap |

- **Shows** a multi-step action split into small functions, a temporary folder from `create_temp_dir`, confirmations graded by risk (`confirm`, and `confirm_phrase` for the riskiest step), and an early `show_completion_summary` before a final reboot prompt.
- **Behavior:** installs normal APT, Flatpak, and Snap updates automatically and respects APT phased updates. Phasing overrides, full upgrades, package removals, driver and firmware installs, and rebooting ask first; full upgrades that remove packages require typing `APPLY`.
- **Settings:** `MIN_ROOT_FREE_GIB`.

### `docker`: Compose projects

| Command | Action |
| --- | --- |
| `maint docker` | Open the Docker menu |
| `maint docker list` | List every container, running or stopped, by Compose project; changes nothing |
| `maint docker update` | Pull newer images, apply the current Compose files, and remove the replaced images |

- **Unit of work:** a Compose project. `update` changes or removes only what the selected projects own: their containers and the images those containers ran. Containers created outside Compose are listed but never updated.
- **Discovery:** reads the local Docker engine on each run; nothing about your containers is configured in the module. Each project is updated with the Compose files, working directory, and environment files recorded on its containers. A project whose files are missing or no longer resolve is reported and skipped. Requires the Docker CLI with Compose v2 and `jq`. Remote endpoints are rejected rather than replaced with the local daemon.
- **Selection:** in a terminal, choose `all` or project numbers separated by spaces/commas; Enter or `0` cancels. Without a terminal, every project is checked, but the confirmation answers No and nothing changes.
- **Update, in order:** check every selected project, show what will happen, and ask once. Then pull every project's images, all before the first change, so a registry failure leaves every project untouched. Then, one project at a time:
  1. Re-read the project's containers.
  2. Bring every service in line with the current Compose files without starting anything: Compose recreates containers whose image or settings changed and removes containers of services no longer defined.
  3. Start the services that were running before and wait until they are running/healthy. Stopped services stay stopped unless a running service depends on them.
  4. Remove the images the project ran before once no container uses them and every remaining tag on them is one the project used. An image another tag still refers to is kept and named in a note.
- **Upgrades:** edit the image tag or settings in the Compose file, then run `update`; the edited definition is what gets applied. Images Compose builds locally are not pulled or rebuilt.
- **Data:** named volumes and bind mounts are kept; the module runs no volume command. Recreation loses in-memory data, tmpfs contents, and changes made inside the container filesystem. A failure stops the action; projects already updated stay updated.
- **Settings and logs:** `DOCKER_WAIT_SECONDS` sets the health wait (120 seconds). The runtime supplies locking, sudo, temporary-file cleanup, and `logs/docker.log`. The module lock coordinates `maint` runs only, not other Docker clients.

Both actions appear automatically in the main menu, help, and Tab completion; reinstalling is unnecessary. Docker Engine itself remains part of `maint sys update` through APT.

## Front ends

The terminal menu is one front end. Another, such as a desktop UI, can drive the same command:

- Discover actions with `maint list`, run one with `maint MODULE ACTION`, and read its exit code: `0` success, `129`/`130`/`143` interrupted, anything else a failure (a command that is not in the list exits with `2`).
- Output lines read `[YYYY-MM-DD HH:MM:SS] [LEVEL] message` (`INFO`, `OK`, `WARN`, `NOTE`, `SUMMARY`, `ERROR`), uncolored when output is not a terminal, interleaved with the output of commands the action runs.
- Without a terminal, every confirmation answers No; each module decides whether a declined step is skipped or stops the action. A front end that approves them must provide its own prompt through `confirm` and `confirm_phrase` in `lib/common.sh`.
- Administrator access goes only through `require_sudo`, `as_root`, and `run_root` in `lib/common.sh`; a front end without a terminal needs a graphical sudo helper there, such as `SUDO_ASKPASS` or pkexec.

## Files

- `maint` — command line, menu, and module registry.
- `lib/run.sh` — runs one action in its own process.
- `lib/common.sh` — settings, logging, locking, privileges, prompts, and cleanup for each action run.
- `modules/` — standalone modules, including `sys.sh` and `docker.sh`.
- `completion.bash` — Tab completion, read from `maint list`.
- `install.sh`, `uninstall.sh`, `icons/` — command, completion, and desktop launcher setup.
- `tests/` — isolated framework and module regression tests.

## Logs

Each module writes to `logs/<module>/YYYY-MM-DD.log`, keeping `LOG_RETENTION_DAYS` days (90) including today; `logs/<module>.log` links to today's file. Every run starts with a `=====` header naming the action, user, and process ID, and every failure or interruption is logged. Only one run of each module proceeds at a time; another says it is waiting and waits up to `LOCK_WAIT_SECONDS` (180).

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
