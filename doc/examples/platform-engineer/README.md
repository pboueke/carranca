# Platform Engineer

## Usage case

This setup fits a platform engineer working in infrastructure, deployment, or
build-system repositories where an agent needs enough tooling to update CI,
packaging, or release automation but should not have general outbound network
access.

The example keeps the runtime on Podman, narrows egress to package registries
and GitHub APIs, mounts SSH keys read-only, and marks deployment-related paths
as watched so policy and audit data stay focused on the highest-risk files.

## Why Carranca is useful

Carranca helps this persona because the main requirement is not just "run a
coding agent in a container." The operator needs enforceable workflow checks,
bounded runtime duration, and evidence showing what the agent executed, touched,
and attempted to reach over the network.

That combination is useful when the same repo contains release credentials,
deployment manifests, and automation that can affect production systems.
