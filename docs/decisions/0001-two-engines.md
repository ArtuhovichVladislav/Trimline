# 0001. Two engines behind one protocol

**Decision.** The UI and `EditorModel` work with the `MediaEngine` protocol and don't know which engine opened the
file. `MediaOpener.open` picks the engine by probing: AVFoundation first, then FFmpeg if AVFoundation can't open
the file or finds no playable stream.

**Why.** AVFoundation adds nothing to the app's size and decodes in hardware, but it doesn't open MKV, WebM, AVI
and the other formats Trimline has to support ([spec](../spec.md#formats)). The protocol let FFmpeg be added
without touching the UI.

**Rejected.** Choosing the engine by file extension: extensions can be wrong.
