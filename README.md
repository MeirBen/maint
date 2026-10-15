# Maintenance

Ubuntu maintenance and local AI scripts in `~/Maintenance`.

## Usage

```bash
update-system           # Update and clean up Ubuntu
local-ai                # Open the action menu
local-ai start          # Start Ollama/Open WebUI and open the chat
local-ai stop
local-ai update         # Update Ollama, the Phi model, and Open WebUI
local-ai status         # Show Ollama, Docker, and Open WebUI status (menu option 4)
```

- Commands ask for your password when needed. Running with `sudo` also works.
- CLI runs exit when finished. Desktop launches wait for Enter. Menus and confirmation prompts still apply in both modes.
- Normal APT, Flatpak, and Snap updates run automatically. APT respects phased updates. Unused Flatpak runtimes and old APT cache files are cleaned automatically.
- Full upgrades, phasing overrides, APT package removals, driver/firmware installs, and rebooting require confirmation. Full upgrades that remove packages require typing `APPLY`.
- `sudo local-ai start` prints the chat URL instead of opening the browser.
- Status reports running, stopped, failed, or transitional service states and Open WebUI's container state/health. It asks for administrator access to inspect the container when Docker is running. If Docker is stopped or a query fails, unavailable status is reported as `UNKNOWN`; status checks do not start services. Exit is menu option 5.
- Container health is shown only while Open WebUI is running; a stopped container's retained health value is not a current health check. A running unhealthy container is reported as a warning.

## Files

- `update-system.sh` — Ubuntu maintenance.
- `local-ai.sh` — local AI controls.
- `lib/common.sh` — shared logging, authentication, prompts, and cleanup.
- `logs/update-system/` and `logs/local-ai/` — `YYYY-MM-DD.log` files containing every run started that day.
- `icons/` and `*.desktop` — desktop launchers and icons.
- `tests/test_toolkit.py` — isolated regression tests.

Only one run of each tool can proceed at a time; another waits up to 180 seconds. Temporary files are cleaned up on exit.

`logs/update-system.log` and `logs/local-ai.log` link to the latest run's daily log. Each tool keeps today and the previous 89 days, removing older logs when it next runs. Existing logs move into daily history under the same retention policy.

## Installed paths

CLI wrappers live in `/usr/local/bin`. Desktop shortcuts link to the `.desktop` files here. If you move this folder, update the wrappers, desktop links, and launcher `Exec`/`Icon` paths. Keep `lib/common.sh` with the scripts.

Local AI uses `/usr/local/sbin/local-ai-service-control` and `/usr/local/libexec/local-ai-update.py`. These helpers and the CLI wrappers are outside this repository; copying it alone does not install them.

## Checks

Run from the repository root (the directory containing `update-system.sh`). For the current installation:

```bash
cd ~/Maintenance
bash -n lib/common.sh
bash -n update-system.sh
bash -n local-ai.sh
python3 -B -m unittest discover -s tests -p 'test_*.py'
```

Tests use temporary files and fake system commands; they do not install updates or change services. Syntax checks print nothing when successful; the test suite ends with `OK`.

Optional lint check, only if ShellCheck is installed (the scripts do not require it):

```bash
shellcheck -x -P SCRIPTDIR lib/common.sh update-system.sh local-ai.sh
```
