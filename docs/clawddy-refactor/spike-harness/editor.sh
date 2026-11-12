#!/bin/sh
# Stand-in external editor: record that it ran (time and file argument) to
# $SPIKE_EDITOR_LOG, leave the file untouched, and exit at once.
echo "$(date '+%s') $*" >> "${SPIKE_EDITOR_LOG:?set SPIKE_EDITOR_LOG}"
exit 0
