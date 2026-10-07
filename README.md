# Maintenance

Ubuntu maintenance and local AI scripts in `~/Maintenance`.

## Usage

```bash
update-system           # Update and clean up Ubuntu
local-ai                # Open the action menu
local-ai start          # Start Ollama/Open WebUI and open the chat
local-ai stop
local-ai update         # Update Ollama, the Phi model, and Open WebUI
```

- Commands ask for your password when needed. Running with `sudo` also works.
- CLI runs exit when finished. Desktop launches wait for Enter. Menus and confirmation prompts still apply in both modes.
- Normal APT, Flatpak, and Snap updates run automatically. APT respects phased updates. Unused Flatpak runtimes and old APT cache files are cleaned automatically.
- Full upgrades, phasing overrides, APT package removals, driver/firmware installs, and rebooting require confirmation. Full upgrades that remove packages require typing `APPLY`.
- `sudo local-ai start` prints the chat URL instead of opening the browser.

## Files

- `update-system.sh` — Ubuntu maintenance.
- `local-ai.sh` — local AI controls.
- `lib/common.sh` — shared logging, authentication, prompts, and cleanup.
- `logs/` — latest `update-system.log` and `local-ai.log`, replaced on each run.
- `icons/` and `*.desktop` — desktop launchers and icons.
- `tests/test_toolkit.py` — isolated regression tests.

Only one run of each tool can proceed at a time; another waits up to 180 seconds. Temporary files are cleaned up on exit.

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
