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
cat > "$fixtures/captions.srt" <<'CAPTIONS'
1
00:00:00,200 --> 00:00:03,800
Caption regression
CAPTIONS
ffmpeg -hide_banner -loglevel error -y -f lavfi -i 'testsrc2=size=320x180:rate=24' \
  -f lavfi -i 'sine=frequency=440:sample_rate=48000' \
  -f lavfi -i 'sine=frequency=880:sample_rate=48000' -i "$fixtures/captions.srt" -t 4 \
  -map 0:v -map 1:a -map 2:a -map 3:s -c:v mpeg4 -threads 2 -c:a aac -c:s srt \
  -metadata:s:a:0 language=eng -metadata:s:a:1 language=por -metadata:s:s:0 language=eng "$fixtures/tracks.mkv"
ffmpeg -hide_banner -loglevel error -y -stream_loop 5 -i "$fixtures/video.mp4" -t 10 \
  -c:v libx264 -threads 2 -preset ultrafast -g 24 -c:a aac -f mpegts "$fixtures/live.ts"
ctest --test-dir "$ps5_root/build/desktop" --output-on-failure
"$ps5_root/build/desktop/brutv_player_test" "$fixtures/video.mp4" "$fixtures/tracks.mkv"
node "$ps5_root/tests/network_test.mjs" "$ps5_root/build/desktop/brutv_player_test" "$fixtures"
