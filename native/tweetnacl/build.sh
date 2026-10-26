#!/bin/sh
# Cross-compile TweetNaCl as a shared library for Kindle (armv7 hard-float, glibc 2.20).
# Requires Zig: `python -m pip install ziglang`.
set -e
cd "$(dirname "$0")"
out=../../orca.koplugin/lib
mkdir -p "$out"
python -m ziglang cc -target arm-linux-gnueabihf.2.17 -mcpu=cortex_a7 -O2 -g0 -s -shared -fPIC \
    -fvisibility=default -Wl,-soname,libtweetnacl.so \
    -o "$out/libtweetnacl.so" tweetnacl.c randombytes.c
echo "built $out/libtweetnacl.so"
