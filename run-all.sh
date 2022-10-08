#!/bin/sh

set -eu

for libc in $(ls ./headers)
do
        for path in $(find ./headers/$libc -type f)
        do
                >&2 echo $path
                 ./zig-out/bin/uh $path
        done
done
