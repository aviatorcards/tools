#!/bin/bash

# Create an 'output' directory if it doesn't exist
mkdir -p mac_ready

for f in *.mp4; do
    echo "Processing $f..."
    # Convert to ProRes 422 with PCM audio (uncompressed)
    ffmpeg -i "$f" \
      -c:v prores_ks -profile:v 3 \
      -c:a pcm_s16le \
      "mac_ready/${f%.mp4}.mov"
done

echo "Done! Check the 'mac_ready' folder."
