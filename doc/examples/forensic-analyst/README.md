# Forensic Analyst Or Incident Responder

## Usage case

This setup is for post-session investigation rather than active coding. The
agent container has no network access, mounts case material and prior Carranca
session archives read-only, and keeps watched paths focused on findings and
report output.

The command drops into a local review shell so the operator can inspect exported
logs, compare evidence, and build a narrative around what happened during a
previous session.

## Why Carranca is useful

Carranca is useful here because it already produces the signed, provenance-rich
evidence the analyst needs to replay what the agent did. Running the review
workflow inside another bounded Carranca session keeps the investigation itself
contained and inspectable.
