#!/usr/bin/env bash
# Generates the test videos in Tests/Fixtures. Every frame carries its own frame
# number as 16 black/white 64x64 blocks along the top edge (bit i at x = 64*i).
set -euo pipefail
cd "$(dirname "$0")/.."
out=Tests/Fixtures
mkdir -p "$out"

strip() {
    echo "nullsrc=s=1024x64:r=$1,format=gray,geq=lum='if(mod(floor(N/pow(2,floor(X/64))),2),235,16)'"
}
ff() { ffmpeg -v error -y "$@"; }

# 1080p H.264, 30 fps, 600 frames, fixed 250-frame GOP with B-frames.
ff -f lavfi -i testsrc2=s=1920x1080:r=30 -f lavfi -i "$(strip 30)" \
   -filter_complex "[0][1]overlay=0:0:shortest=1,format=yuv420p" -frames:v 600 \
   -c:v libx264 -g 250 -keyint_min 250 -sc_threshold 0 -bf 3 -crf 18 "$out/h264_cfr_gop250.mp4"

# 4K HEVC 10-bit HLG, 120 frames, open GOP (x265 default); the seek back-off is exercised by seeking it through approximateIndex().
ff -f lavfi -i testsrc2=s=3840x2160:r=30 -f lavfi -i "$(strip 30)" \
   -filter_complex "[0][1]overlay=0:0:shortest=1,format=yuv420p10le" -frames:v 120 \
   -c:v libx265 -x265-params log-level=error:keyint=60:min-keyint=60:scenecut=0:colorprim=bt2020:transfer=arib-std-b67:colormatrix=bt2020nc -crf 20 \
   -color_primaries bt2020 -color_trc arib-std-b67 -colorspace bt2020nc -tag:v hvc1 "$out/hevc10_hlg.mov"

# Variable frame rate: frames 0-59 last 2/60 s, frames 60-119 last 1/60 s.
ff -f lavfi -i testsrc2=s=1280x720:r=30 -f lavfi -i "$(strip 30)" \
   -filter_complex "[0][1]overlay=0:0:shortest=1,format=yuv420p,settb=1/60,setpts='if(lt(N,60),N*2,120+(N-60))'" \
   -frames:v 120 -fps_mode passthrough -enc_time_base 1/60 -c:v libx264 -g 40 \
   -video_track_timescale 60 "$out/h264_vfr.mp4"

# AV1, 120 frames.
ff -f lavfi -i testsrc2=s=1920x1080:r=30 -f lavfi -i "$(strip 30)" \
   -filter_complex "[0][1]overlay=0:0:shortest=1,format=yuv420p" -frames:v 120 \
   -c:v libsvtav1 -g 60 -svtav1-params loglevel=0 "$out/av1.mkv"

# 640x360, 25 fps, 4 s, with a 440 Hz AAC tone.
ff -f lavfi -i testsrc2=s=640x360:r=25 -f lavfi -i "$(strip 25)" \
   -f lavfi -i sine=frequency=440:sample_rate=48000 \
   -filter_complex "[0][1]overlay=0:0:shortest=1,format=yuv420p[v]" -map "[v]" -map 2:a -t 4 \
   -c:v libx264 -c:a aac -shortest "$out/withaudio.mp4"

# The same with a keyframe every second (frames 0/25/50/75), for clips joined from several GOPs.
ff -f lavfi -i testsrc2=s=640x360:r=25 -f lavfi -i "$(strip 25)" \
   -f lavfi -i sine=frequency=440:sample_rate=48000 \
   -filter_complex "[0][1]overlay=0:0:shortest=1,format=yuv420p[v]" -map "[v]" -map 2:a -t 4 \
   -c:v libx264 -g 25 -keyint_min 25 -sc_threshold 0 -c:a aac -shortest "$out/withaudio_gop25.mp4"
# The same in Matroska: after a seek its demuxer gives the first B-frame-delayed packets no dts.
ff -i "$out/withaudio_gop25.mp4" -c copy "$out/withaudio_gop25.mkv"

# Same clip with a display matrix. -display_rotation is counter-clockwise: 90 means 270 clockwise.
ff -display_rotation 90 -i "$out/withaudio.mp4" -c copy "$out/rotated.mp4"
ff -display_rotation 180 -i "$out/withaudio.mp4" -c copy "$out/rotated180.mp4"
ff -display_rotation -90 -i "$out/withaudio.mp4" -c copy "$out/rotated90.mp4"
# Mirrored matrices: a plain horizontal flip, and a flip after a 90-degree turn (shown as rotated.mp4 mirrored).
ff -display_rotation 0 -display_hflip -i "$out/withaudio.mp4" -c copy "$out/hflip.mp4"
ff -display_rotation 90 -display_hflip -i "$out/withaudio.mp4" -c copy "$out/hflip_rotated.mp4"

# Same clip with its audio starting 2 s after the video (scrub audio: frames before the audio are silent).
ff -i "$out/withaudio.mp4" -itsoffset 2 -i "$out/withaudio.mp4" -map 0:v -map 1:a -c copy "$out/audiolate.mp4"

# Same clip with the audio read ahead of the video: fragmented, audio as the first track, ~1 s fragments, so each
# fragment's audio comes before its video.
ff -i "$out/withaudio.mp4" -map 0:a -map 0:v -c copy -movflags +frag_keyframe+empty_moov+default_base_moof \
   -frag_duration 1000000 "$out/audiolead.mp4"

# A video stream FFmpeg can mux but not decode (no a64_multi decoder): opens, never decodes.
ff -f lavfi -i testsrc=s=320x200:r=25 -frames:v 250 -c:v a64multi -f nut "$out/nodecoder.nut"

# Fragmented MP4 (moof boxes) and an edit list (stream copy from 1 s: frames before it are discarded).
ff -i "$out/h264_vfr.mp4" -c copy -movflags +frag_keyframe+empty_moov "$out/h264_frag.mp4"
ff -ss 1 -i "$out/h264_cfr_gop250.mp4" -c copy "$out/h264_editlist.mp4"

# Anamorphic PAL 16:9 (720x576, SAR 64:45) with a letterboxed picture: 88-pixel black bars top and bottom,
# 50 frames, a keyframe every 10. No frame-number strip: it would light up the top bar.
ff -f lavfi -i testsrc2=s=720x400:r=25 -vf "pad=720:576:0:88:black,setsar=64/45,format=yuv420p" -frames:v 50 \
   -c:v libx264 -g 10 -keyint_min 10 -sc_threshold 0 "$out/anamorphic_letterbox.mp4"

# Scene jumps: 320x180, 25 fps, 175 frames, a keyframe every 25 (0, 25, ... 150). Scenes start at 0 (testsrc),
# 50 (black, frames 50-74), 75 (smptebars) and 125 (rgbtestsrc).
ff -f lavfi -i testsrc=s=320x180:r=25:d=2 -f lavfi -i color=black:s=320x180:r=25:d=1 \
   -f lavfi -i smptebars=s=320x180:r=25:d=2 -f lavfi -i rgbtestsrc=s=320x180:r=25:d=2 \
   -filter_complex "[0][1][2][3]concat=n=4:v=1,format=yuv420p" \
   -c:v libx264 -g 25 -keyint_min 25 -sc_threshold 0 "$out/scenes.mp4"

# Scene jumps inside a GOP: 320x180, 25 fps, 125 frames, keyframes 0, 50 and 100. testsrc for frames 0-59, smptebars
# from 60: the cut lies inside the GOP 50-100.
ff -f lavfi -i testsrc=s=320x180:r=25 -f lavfi -i smptebars=s=320x180:r=25 \
   -filter_complex "[0]trim=end_frame=60[a];[1]trim=end_frame=65,setpts=PTS-STARTPTS[b];[a][b]concat=n=2:v=1,format=yuv420p" \
   -c:v libx264 -g 50 -keyint_min 50 -sc_threshold 0 "$out/scenes_midgop.mp4"

# Audio whose layout changes mid-stream: 320x180 25 fps video, 2 s of stereo AAC, then 2 s of mono, joined as MPEG-TS (the way joined
# recordings arrive). The decoder's frames change channel count after 2 s.
tmp=$(mktemp -d)
for part in "a 440 2" "b 660 1"; do
    set -- $part
    ff -f lavfi -i testsrc=s=320x180:r=25:d=2 -f lavfi -i sine=f=$2:r=48000:d=2 -ac $3 -c:v libx264 -g 25 -c:a aac \
       -f mpegts "$tmp/$1.ts"
done
cat "$tmp/a.ts" "$tmp/b.ts" > "$out/audio_layout_change.ts"
rm -r "$tmp"

ls -la "$out"
