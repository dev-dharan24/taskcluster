# Taskcluster `icacls` reparse-point reproduction

This temporary validation harness checks commit
`726ac7a1ba6c550356a5f0498608a559c758970e` on GitHub-hosted Windows Server
2022 and 2025 runners.

The PowerShell script creates only two directories beneath `RUNNER_TEMP`: a
cache-shaped directory and an outside sentinel directory. It places an NTFS
junction in the cache, changes owners with the exact affected
`icacls <cache> /setowner <user> /T` argument shape, records both outside
owners, compares `/L /T`, and removes the temporary junction before deleting
the directories.

The `/L /T` result is recorded rather than assumed safe. On the first run,
both Windows versions showed that `/L` changes how the junction itself is
handled but does not stop `/T` from enumerating and re-owning files through the
junction.

No Taskcluster service, credential, worker pool, or production path is used.
