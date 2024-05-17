#!/bin/bash

# make sure this is an ubuntu or debian machine
if [ -f /etc/os-release ]; then
  . /etc/os-release
  if [ "$ID" != "ubuntu" ] && [ "$ID" != "debian" ]; then
    echo "The linux release should be built on an Ubuntu or Debian system."
    exit 1
  fi
else
  echo "The linux release should be built on an Ubuntu or Debian system."
  exit 1
fi

release_dir=./linux/lucid
lib_dir=$release_dir/lib


mkdir -p $lib_dir
# 1. build the binary locally (in the parent directory)
cd ..
make
cd - 

# copy binary
cp ../dpt "$release_dir"/dpt

# Run ldd on the binary and parse output
deps=$(ldd "$release_dir"/dpt | awk '/=>/ {print $3} !/=>/ {if ($1 ~ /^\//) print $1}')

# Exclude system libs that come with linux
exclude_libs="libc.so.6 libstdc++.so.6 libgcc_s.so.1 ld-linux-x86-64.so.2 libpthread.so.0 libdl.so.2 libm.so.6"
for lib in $deps; do
  base_lib=$(basename "$lib")
  if [[ " $exclude_libs " =~ " $base_lib " ]]; then
    echo "Skipping $lib"
    continue
  fi
  if [ -f "$lib" ]; then
    echo "Copying $lib to $lib_dir"
    cp "$lib" "$lib_dir"
  else
    echo "Library $lib not found."
  fi
done

patchelf --set-rpath '$ORIGIN/lib' "$release_dir"/dpt

echo "======================"
echo "Linux binary package built in $release_dir. Please distribute this entire folder and run dpt inside of it."
echo "======================"