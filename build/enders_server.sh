#!/bin/sh
printf '\033c\033]0;%s\a' EndersGameInspo
base_path="$(dirname "$(realpath "$0")")"
"$base_path/enders_server.x86_64" "$@"
