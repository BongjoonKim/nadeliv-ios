#!/bin/zsh
# 가짜 백엔드용 샘플 파일(사진 14장 + 영상 1개)을 만든다. 한 번만 실행하면 된다.
set -e
cd "$(dirname "$0")"
mkdir -p files
src="/System/Library/Desktop Pictures/.thumbnails"
i=0
for f in "$src"/*.heic; do
  i=$((i+1))
  sips -s format jpeg "$f" --out "files/p$i.jpg" -Z 2400 >/dev/null
  sips -s format jpeg "$f" --out "files/p$i-thumb.jpg" -Z 400 >/dev/null
  [ $i -ge 14 ] && break
done
cp files/p7-thumb.jpg files/v1-thumb.jpg
swiftc -O makevideo.swift -o .makevideo 2>/dev/null
./.makevideo "$PWD/files"
echo "샘플 파일 준비 완료: $(ls files | wc -l | tr -d ' ')개"
