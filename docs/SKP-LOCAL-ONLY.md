# Source SKP privacy and corpus evidence (2026-10-19)

Source `.skp` models must not be tracked or uploaded to this repository. The existing `.gitignore` already includes `*.skp`, but tracked legacy files bypass ignore rules. The five tracked source SKP files are deleted from the current Git tree without rewriting historical commits. Existing local files on D: are outside this GitHub change and must not be deleted.

The seven manifest SKP models are `local_untracked` and retain their original declared byte lengths and SHA-256 so a Windows SketchUp qualification worker can verify genuine files. The test keeps all seven model-eval JSON fixture encoding, decoding and fidelity checks, but when a source SKP is absent the corresponding three-profile certification is **INCOMPLETE** with `source_skp: missing`; it is never called PASS. A missing SKP is not generated, replaced with synthetic content, or sourced from an untrusted download.

The legacy tiny-box JSON fixture has 1,376 bytes and SHA-256 `b31fbf6c933a23013d927e1015d069663567acb293a1ce36e6d6296565efeff4` in the original repository import (commit 657d867). The earlier corpus entry claimed 1,377 bytes and a nonmatching SHA despite no fixture content change. This correction pins the actual unchanged fixture bytes and leaves all other fixture digests and product tolerance thresholds untouched.

Clean CI should report an incomplete source-model corpus while its regression tests PASS: that means the fail-closed contract works, *not* that E4 has been certified on actual SketchUp models. Historical Git objects still retain previously committed SKP blobs until a separately planned destructive history rewrite; existing clones should be treated accordingly.
