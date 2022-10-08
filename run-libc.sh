#!/bin/sh

set -eu

for path in $(find headers/x86_64-linux-musl -type f)
do
        >&2 echo $path
         ./zig-out/bin/uh $path
done
