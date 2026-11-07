#!/bin/sh
# Uploads MIDI files to the PianoWait bucket: tools/upload_midi.sh song.mid folder/ ...
# Run with no arguments to list what is in the bucket.
set -eu

script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

if [ "$#" -eq 0 ]; then
    exec python3 "$script_directory/upload_midi.py" list
fi
exec python3 "$script_directory/upload_midi.py" upload "$@"
