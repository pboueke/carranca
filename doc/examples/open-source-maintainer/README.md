# Open-Source Maintainer

## Usage case

This setup fits a maintainer reviewing external contributions or asking an
agent to prepare follow-up fixes while keeping a close eye on project policy and
high-signal repo metadata such as CI workflows and security documentation.

The example leaves networking enabled for ordinary package and repository work
but still watches maintainer-controlled paths and records enough telemetry to
make an external agent-generated patch easier to review.

## Why Carranca is useful

Carranca helps because a maintainer often needs more context than a bare diff.
Session evidence, watched-path events, and command history make it easier to
decide whether an agent-generated change looks trustworthy before merging or
requesting revisions.
