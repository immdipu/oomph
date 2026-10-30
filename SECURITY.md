# Security Policy

## Reporting a vulnerability

Please don't open a public issue for security problems. Report them privately through
[GitHub's private vulnerability reporting](https://github.com/immdipu/oomph/security/advisories/new)
with steps to reproduce and the Oomph and macOS versions affected. You'll get a reply within a
week, and credit in the release notes if you'd like it.

## Scope

Oomph runs the bundled eqtune engine with arguments it builds itself and reads preset files the
user chooses. Issues in Oomph's own code (command construction, file handling, the bundled
binary and its signing) belong here. Issues in the audio engine itself belong to
[eqtune](https://github.com/y7nieSEl5/eqtune).

Oomph makes no network connections. Audio is processed on the Mac by eqtune and never leaves it.

## Supported versions

Security fixes go into the latest release on `main`.
