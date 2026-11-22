#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p tmp/audio-lifecycle
sources=(Ramblr/AudioManager.swift Ramblr/AudioCaptureEngine.swift Ramblr/MicrophoneManager.swift Tests/AudioTestLogging.swift)
swiftc "${sources[@]}" Tests/AudioLifecycleChecks.swift -o tmp/audio-lifecycle/checks
tmp/audio-lifecycle/checks
swiftc "${sources[@]}" Tests/AudioBufferChecks.swift -o tmp/audio-lifecycle/buffer-checks
tmp/audio-lifecycle/buffer-checks
