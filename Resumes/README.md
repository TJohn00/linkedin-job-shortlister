# Put your CV here

Drop a single PDF in this folder. The pipeline picks the **most recently
modified** `.pdf` automatically — the filename is never hardcoded, so you can
name it whatever you like and just drop in a newer version later.

`scripts/resume-sync.ps1` fingerprints it with SHA256 and records the hash in
`state/resume.hash`. `state/profile.md` is only regenerated when that hash
changes, so editing your CV triggers a rebuild and nothing else does.

Everything in this folder except this file is git-ignored — your CV will not be
committed.
