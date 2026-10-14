#!/bin/bash
# One-line build state: phase | progress | running make target | errors
echo "--- procs ---"
pgrep -a -f 'make|build-efusefix|cc1|apply.sh' | head -5
echo "--- log tail ---"
tail -6 ~/build-efusefix.log 2>/dev/null
echo "--- PHASE markers ---"
grep -h '^PHASE' ~/build.log 2>/dev/null | tail -5
echo "--- apply.sh witness in build.log ---"
grep -h -E 'Try the file first|witness|mt76' ~/build.log 2>/dev/null | tail -6
