# Native silent installer reproduction

Temporary Windows-only diagnostic matrix for the previously observed `0xC0000005` exit during a fresh `/S /D=...` install. It runs the exact protected candidate and a previous protected baseline in disposable GitHub-hosted Windows VMs.

Each case records parent/child process observations, exit status, installed files, allowlisted crash-event fields and shortcut/uninstall metadata. Native dumps, channel bindings, tokens and application source are not published. This is a diagnostic test and does not change product code or publish a release.

Candidate SHA256: `3a6860d8d546055393c451f487f6240c5570f982b5038370978efc82cda8d091` (source `a905f75313ad78c714b4e0499d4a4d8128d16641`).

Baseline SHA256: `8c6e65404bb751ab674f70dc41a9a9ff2a9eb4f82ad69814a2251bb8f6d2102a`.
