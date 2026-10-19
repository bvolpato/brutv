#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# CMake's LINKER: syntax is compiler-driver oriented. This adapter preserves its
# argument boundaries while invoking lld directly, as the public SDK requires.
set -euo pipefail
args=()
while (( $# )); do
    case "$1" in
        -Xlinker)
            shift
            (( $# )) || { echo 'Missing -Xlinker argument' >&2; exit 2; }
            args+=("$1")
            ;;
        -Wl,*)
            IFS=, read -r -a flags <<< "${1#-Wl,}"
            args+=("${flags[@]}")
            ;;
        -pthread) args+=(-lpthread) ;;
        *) args+=("$1") ;;
    esac
    shift
done
exec ld.lld-18 -m elf_x86_64 -pie -z max-page-size=0x4000 \
    --hash-style=gnu --eh-frame-hdr -mllvm -emulated-tls "${args[@]}"
