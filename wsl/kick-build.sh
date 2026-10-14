#!/bin/bash
# Launch the efuse-fix build detached, then prove it is actually running.
# Doing this inside a script file matters: inline wsl.exe command lines lose
# $! / quoting through MSYS, and a launch that silently dies looks like a build
# that never finished.
cd "$HOME" || exit 1
rm -f "$HOME/build-efusefix.log"
setsid nohup bash "$HOME/e2631/wsl/build-efusefix.sh" > "$HOME/build-efusefix.log" 2>&1 < /dev/null &
sleep 5
echo "launcher rc of sleep: $?"
pgrep -a -f 'build-efusefix|make' | head -4
echo "log so far: $(wc -c < "$HOME/build-efusefix.log" 2>/dev/null) bytes"
tail -3 "$HOME/build-efusefix.log" 2>/dev/null
