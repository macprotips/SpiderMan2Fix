# Report for Apple: the M1 to M4 T-pose bug

This folder holds everything Apple needs to understand, reproduce and fix the Marvel's
Spider-Man 2 T-pose bug on M1 to M4 Macs.

| File | Purpose |
| --- | --- |
| [`APPLE.md`](APPLE.md) | Report for Apple (Feedback Assistant). The root cause is in D3DMetal. |
| `repro/` | Attachments: a standalone D3D12 test with source, a native Metal check, and results and logs from an M3 Max |

## How to file

Open Feedback Assistant and create a new macOS report. Pick the Game Porting Toolkit /
D3DMetal area if it's offered. Paste the title and body from `APPLE.md`, fill in the
CrossOver version in square brackets (CrossOver › About CrossOver), then attach a zip of this
folder.
