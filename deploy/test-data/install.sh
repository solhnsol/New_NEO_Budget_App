#!/bin/sh
# Run on the RPi as the archive owner. Does not need sudo or change live apps.
set -eu
repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
install -d -m 700 "$HOME/.local/lib/neo-test-data" "$HOME/.local/share/neo-test-data" "$HOME/.config/systemd/user"
install -m 600 "$repo_dir/tools/test_data/export.py" "$HOME/.local/lib/neo-test-data/export.py"
install -m 600 "$repo_dir/deploy/test-data/neo-test-data.service" "$HOME/.config/systemd/user/neo-test-data.service"
install -m 600 "$repo_dir/deploy/test-data/neo-test-data.timer" "$HOME/.config/systemd/user/neo-test-data.timer"
systemctl --user daemon-reload
systemctl --user start neo-test-data.service
systemctl --user enable --now neo-test-data.timer
systemctl --user list-timers neo-test-data.timer --no-pager
