# Security policy

## Supported versions

Fixes are made on the latest release only.

| Version | Supported |
| --- | --- |
| 1.0.x | Yes |
| Older | No |

## Reporting a vulnerability

Please do not open a public issue for a security problem.

Report it privately through GitHub: on the repository's **Security** tab, choose **Report a vulnerability**. That opens a private advisory visible only to you and the maintainer.

Include what you can of:

- the macOS version and the Notchmix version or commit
- what an attacker could do, and what they would need to do it
- steps to reproduce

You should get a reply within a week. Once a fix is released, the advisory is published and you are credited unless you ask not to be.

## What is in scope

Notchmix reads other apps' audio in order to replay it at a chosen level, and sends Apple Events to Safari and Spotify. Reports of particular interest:

- audio being stored, transmitted, or exposed to another process
- a way for another app to make Notchmix act on its behalf
- the app leaving an app muted, or an audio device behind, after it exits
- anything in the build or signing process that could alter the shipped binary
