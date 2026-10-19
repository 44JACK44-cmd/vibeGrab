"""End-to-end check of the MP3 conversion with real ffmpeg + real tags.

Not part of the test suite: it needs the ffmpeg binary. Run it from backend/
with FFMPEG_PATH pointing at a real ffmpeg to verify that the produced file is
a playable MP3 carrying the title, the artist and the cover.
"""

import os
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from app.services.audio_service import ffmpeg_args  # noqa: E402

work = Path(os.environ.get("TEMP", ".")) / "vibegrab-mp3-check"
work.mkdir(parents=True, exist_ok=True)
ffmpeg = os.environ["FFMPEG_PATH"]

src_m4a = work / "tone.m4a"
cover = work / "cover.jpg"
out = work / "out.mp3"

subprocess.run(
    [ffmpeg, "-y", "-f", "lavfi", "-i", "sine=frequency=440:duration=3",
     "-c:a", "aac", str(src_m4a)],
    capture_output=True, check=True,
)
subprocess.run(
    [ffmpeg, "-y", "-f", "lavfi", "-i", "color=c=red:s=320x320:d=1",
     "-frames:v", "1", str(cover)],
    capture_output=True, check=True,
)

cmd = ffmpeg_args(
    src_m4a,
    out,
    title="Cancion de prueba — con acentos",
    artist="VibeGrab",
    cover=cover,
)
print("ffmpeg:", " ".join(cmd[1:]))
result = subprocess.run(cmd, capture_output=True, text=True)
print("exit:", result.returncode)
if result.returncode != 0:
    print(result.stderr[-800:])
    sys.exit(1)

from mutagen.id3 import ID3  # noqa: E402
from mutagen.mp3 import MP3  # noqa: E402

audio = MP3(str(out))
tags = ID3(str(out))
print("size:", out.stat().st_size, "bytes")
print("duracion:", round(audio.info.length, 2), "s  bitrate:", audio.info.bitrate)
print("title:", tags.get("TIT2"))
print("artist:", tags.get("TPE1"))
apic = tags.getall("APIC")
print("portadas:", len(apic), "mime:", apic[0].mime if apic else None,
      "bytes:", len(apic[0].data) if apic else 0)
