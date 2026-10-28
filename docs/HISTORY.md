# Initial History Curation

The initial history is a dependency-ordered import of an existing local implementation.
It is not the original development chronology, and no author or committer dates were backdated.
The previous local history is preserved at `backup/before-history-curation-3d86063`.

The import introduces the Swift library before its engines, tests with their target declarations,
and the executable before Xcode packaging. UI imports separate application state, the workspace,
operation results, and help. An already implemented audio-timing safeguard is isolated for review;
it rejects affected AAC clips and does not claim to repair their timing.

Every commit in this curated sequence was materialized in an isolated checkout and built.
Where a test target exists, its tests were run. Encoder-dependent CLI skips remain explicitly
reported as skips. Once the Xcode project exists, that target was also built. Validation runners
were compiled when introduced. Compiler sandbox workarounds apply to build tools only.

The archived browser prototype is a larger mechanical reference import, excluded from native
builds. Future functional work should use small changes with focused regression tests rather
than reconstructing another development narrative.

Verification details and per-step results are stored locally under `.build/history-curation/`.
No remote refs were changed or pushed during curation.
