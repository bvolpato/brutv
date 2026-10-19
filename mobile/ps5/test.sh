#!/usr/bin/env bash
set -euo pipefail
ps5_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
bash "$ps5_root/build.sh" -DBUILD_TESTING=ON
fixtures="$ps5_root/build/fixtures"
mkdir -p "$fixtures/hls"
ffmpeg -hide_banner -loglevel error -y -f lavfi -i 'testsrc2=size=320x180:rate=24' \
  -f lavfi -i 'sine=frequency=440:sample_rate=44100' -t 2 \
  -c:v mpeg4 -threads 2 -c:a aac -movflags +faststart "$fixtures/video.mp4"
ffmpeg -hide_banner -loglevel error -y -i "$fixtures/video.mp4" \
  -c:v libx264 -threads 2 -preset ultrafast -g 24 -c:a aac \
  -hls_time 1 -hls_playlist_type vod -hls_segment_filename "$fixtures/hls/part-%03d.ts" "$fixtures/hls/index.m3u8"
ctest --test-dir "$ps5_root/build/desktop" --output-on-failure
"$ps5_root/build/desktop/brutv_player_test" "$fixtures/video.mp4"
node "$ps5_root/tests/network_test.mjs" "$ps5_root/build/desktop/brutv_player_test" "$fixtures"
