# Consultant Working On Client Code

## Usage case

This setup is for a consultant who wants local agent help inside a client
repository without sending that repository into a hosted sandbox they do not
control. The agent can still reach a narrow set of endpoints needed for package
metadata or repository workflows, but sensitive client paths are watched and
optionally made read-only.

The example also disables Carranca cache persistence so client context does not
linger in the default cache volumes between engagements.

## Why Carranca is useful

Carranca is useful because the consultant often needs to demonstrate restraint,
not just output. Local execution, auditable logs, and path-level guardrails make
it easier to justify how the agent interacted with client-owned code and
materials.

That is a materially different operating model from a generic hosted coding
sandbox.
