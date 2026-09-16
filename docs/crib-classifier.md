# Local crib-presence classifier

Nanight uses Apple's MobileCLIP-S2 image encoder through Core ML (`computeUnits = .all`). It compares normalized image embeddings with two averaged, normalized text embeddings: baby in crib and empty crib. The text prompts and vectors are in `Nanight/PresenceModel/CribPrompts.json`. No user images were used to train the model or embedded in the app.

The classifier checks the full frame and six overlapping crops, taking the greatest baby-minus-empty cosine similarity. A positive requires baby similarity >= 0.2 and margin >= 0.015. These are heuristic decision thresholds, not calibrated probabilities. Two positive samples confirm the In bed indicator. It samples every three seconds and allows only one inference at a time. Presence uses three-way evidence: present, confidently empty, or uncertain. Two minutes of continuously empty evidence end presence; three minutes without positive evidence expire uncertain presence. Brief video interruptions can recover the same presence block within 30 seconds; they clear sleep evidence immediately. Camera changes and clearing history reset everything. In bed and Sleeping are separate indicators. Sleeping is an estimate from sustained low local image movement while a baby is present, not confirmed sleep.

## Evaluation on September 14, 2026

The exact Swift classifier, including Core Image preprocessing, passed the three user-supplied examples and grayscale, exposure, and mirror variants: 15/15 checks. These are three source scenes, not 15 independent validation images. They were used for model selection, so this is a regression/evaluation set, not an unseen accuracy benchmark.

| Original image | Expected | Result | Cosine margin |
| --- | --- | --- | --- |
| Daylight, baby | Present | Present | 0.0282 |
| Infrared, baby | Present | Present | 0.0245 |
| Empty crib | No positive detection | No positive detection | -0.0321 |

Warm native classification took 26-28 ms per frame including all seven crops on the development Mac. Initial model load plus first inference took 1.44 seconds. These measurements do not establish energy usage on other Macs. The bundled image weights are approximately 71 MB; the text model is not bundled.

The original Vision human detector missed the baby. MobileCLIP-S0 remained borderline on daylight variants; S2 separated all evaluated variants. Neither a faded indicator nor a low score establishes that the crib is empty. Other bedding, camera angles, toys, adult visits, occlusions, and new day/night conditions remain unvalidated.

## Reproduce using private local images

Build Nanight first, then compile the evaluation executable:

```sh
swiftc -parse-as-library Nanight/NanightRestState.swift Nanight/NanightCribClassifier.swift scripts/evaluate-crib-classifier.swift -o /tmp/evaluate-crib-classifier
/tmp/evaluate-crib-classifier \
  build/Presence/Build/Products/Debug/Nanight.app/Contents/Resources/mobileclip_s2_image.mlmodelc \
  Nanight/PresenceModel/CribPrompts.json \
  "$DAY_BABY_IMAGE" "$INFRARED_BABY_IMAGE" "$EMPTY_POPOVER_IMAGE"
```

The third argument's border crop is specific to the supplied 850x488 popover screenshot. Other images should be full camera frames or use a suitable crop. The production classifier has no screenshot-specific coordinates. User images stay outside the repository. The evaluation exits nonzero for any mismatch.

## Model source and licensing

- Image weights SHA-256: `6cbc7fb06b6072c1cae9c4496d67e0e6217adbf726dfeb82e44d4efe87c34c00`
- Core ML model: https://huggingface.co/apple/coreml-mobileclip
- Original S2 model code/demo: https://github.com/apple/ml-mobileclip
- The original MobileCLIP weights license is retained as `Nanight/PresenceModel/MobileCLIP-LICENSE.txt`, from https://github.com/apple/ml-mobileclip/blob/341ef058802f0e4e5ab13c02f0cb32a3a94e367b/LICENSE_weights_data. This is the original MobileCLIP model, not MobileCLIP2.
- Text vectors use the matching S2 text encoder, CLIP token IDs with start/end tokens, zero-padding to 77 tokens, per-prompt L2 normalization, then mean and L2 normalization. No runtime tokenizer or text model is needed.

Diagnostics use OSLog subsystem `com.tanooj.Nanight`, category `presence`. They report similarities, margin, time, and state only. Video frames and image embeddings are neither logged nor stored.

## Estimated sleep and activity blocks

`NanightLocalMotion` compares 64x48 grayscale samples of the central 70% of the frame. It removes mean brightness drift and marks activity when more than 4% of pixels change by over 0.07. An exposure jump of 0.15 or more invalidates the motion baseline. These thresholds are initial heuristics, not validated sleep-scoring parameters. Adults, shadows, camera shifts, and movements between samples can affect the estimate. Audio is not used because cloud sound notifications do not identify the sound source.

`NanightRestState` requires 120 seconds of low movement after presence confirmation to begin an estimated sleep interval. It clears sleep after 30 seconds of sustained activity, so brief movement stays in one block. A confidently empty result requires empty similarity >= 0.2 and baby-minus-empty margin <= -0.015. Borderline results are uncertain, not empty. Presence is preserved for short interruptions up to 30 seconds, but its stored end advances only when a positive reading returns. Longer missing-sample gaps create a new session. Sleep evidence is still discarded after a sampling interruption over eight seconds. Live sleep starts at confirmation; the retrospective gap rule below can extend a history block earlier. Unknown motion clears live estimated sleep.

## Observation pipeline

Frames -> saved numeric observations -> analysis -> indicators and activity blocks.

`NanightBabyPresence` samples a frame every three seconds. The classifier produces baby and empty similarities; `NanightLocalMotion` produces changed-pixel fraction, brightness change, and baseline validity. The frame and temporary image data stay in memory. `NanightActivityStore` first appends these numbers, timestamp, session, extractor/model identity, and inference duration to SQLite's `signal_observations` table. Interruptions, resets, and inference failures are saved as boundary observations. No images or embeddings are saved.

`NanightSignalAnalysis` interprets saved scores and movement values, using `NanightRestState` for temporal smoothing. The returned state drives In bed and Sleeping; its intervals drive history and hover tooltips. There is no second history-only smoothing rule. Short contradictory classifications remain available in the numeric record even when the analysis keeps one continuous block.

Analysis is cached per camera in memory and rebuilt chronologically from saved observations on launch or when a delayed observation arrives out of order. Normal sampling updates it incrementally. Changing analysis rules automatically changes the next replay without overwriting evidence. Old derived `state_blocks` rows are no longer read; no migration is needed. Clearing history deletes numeric observations and the analysis cache, and rejects queued pre-clear samples.

Activity history displays In bed in mint and estimated Sleeping in cyan. Hovering a block shows its full start, end (latest supporting observation for an active block), and duration, including across midnight. Cloud motion/sound events remain a separate existing activity track; they are not used as sleep evidence.

## Retrospective inference across unavailable video

The analysis can now bridge a gap of more than 30 seconds and up to two hours when the same session has at least 30 seconds of supported presence before the gap and 30 seconds of continuously positive readings after return. This covers laptop closure and stream outages, including saved history without a specific laptop-sleep marker. It does not assert why the video was unavailable. Empty/uncertain readings, resets, session changes, inference failures, and longer gaps prevent bridging. A sampling gap over eight seconds during confirmation cancels that confirmation.

Presence does not imply sleep. To extend estimated sleep across a bridged gap, the last 30 seconds before loss of video must be quiet, and the returned video must establish 120 seconds of quiet presence. The initial missing motion baseline is allowed up to eight seconds after return. A missing motion baseline lasting at most eight seconds can preserve quiet evidence across a brief stream restart. Actual movement after return blocks sleep bridging. Confirmation must complete within five minutes of return. If sleep was already established before the gap, the same sleep block continues retrospectively. Otherwise its inferred start is two minutes after the pre-gap quiet period began. These are tunable heuristics, not observations of what happened with the laptop closed.

`NanightGapInference` applies this inside the shared analysis layer. No fabricated observations are saved. Inferred intervals are attached to derived blocks and listed in their hover tooltips. Total block durations include the inference, but the observed-time counter is unchanged. No live presence or sleeping indicator is enabled during the gap; confirmation requires new frames. Replay uses these rules automatically on the next app launch.
