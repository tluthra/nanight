# Nanight playback patches

Source: https://github.com/HaishinKit/HaishinKit.swift
Upstream version: 2.2.5
Upstream revision: dc880cb540b8feeb98f64e8b7dcfaaf320b6b2bd
License: BSD-3-Clause, retained in LICENSE.md and in Nanight's ThirdPartyNotices.txt.

Only HaishinKit/Sources and RTMPHaishinKit/Sources are included. The manifest
exposes those two products and pins the existing Logboard 2.6.0 dependency.
No examples, tests, documentation plugins, or unrelated transport products are
included. This local package makes the fixes reproducible without editing Xcode's
package cache or publishing a fork.

Changes from that revision:

- MediaLink.swift: use elapsed monotonic time, anchored to the first frame, when
  no audio player supplies a clock. The upstream macOS display link's default
  targetTimestamp minus timestamp is zero, which freezes video after frame one.
- DisplayLinkChoreographer.swift: stop an active CVDisplayLink when invalidating
  it. The previous guard only stopped already-paused links, leaking callbacks
  across reconnects.
- RTMPMessage.swift / RTMPStream.swift: allocate a separate, correctly sized
  compressed audio buffer for each packet and capture its timestamp before
  asynchronous decoding. Validate truncated packets and destination capacity.
  A shared mutable buffer allowed the next packet to overwrite a queued one.
- RTMPStream.swift: snapshot video timestamps and format descriptions before
  asynchronous decoding so subsequent packets cannot change queued timing.
- AudioCodec.swift: pass each owned compressed packet to the decoder once,
  without copying it into a fixed-size 1024-byte scratch buffer.
- RTMPStream.swift: do not pass decoded playback audio/video into outgoing
  encoders. Playback outputs still receive the decoded buffers normally.

Regression tests: NanightTests/PlaybackPipelineTests.swift. The original
videoQueueAdvancesWithoutAnAudioPlayer test failed with 1 of 6 frames received;
it passes with this patch. Retest playback, pause/resume, and sleep/wake before
replacing this package with any upstream update.
