# FAQ

**Why Bash?**

The entire runtime is ~4000 lines of auditable shell that calls `podman`/`docker`
directly. No framework, no compiled binary the operator can't read, no transitive
dependencies. `shellcheck` enforces lint on every commit.

**`eval` of `AGENT_COMMAND` looks dangerous**

`.carranca.yml` is operator configuration, like a Makefile or CI workflow. The
operator controls what command runs. Carranca does not accept agent-authored
commands. The config is hidden from the agent at runtime.

**The HMAC key is on the same machine**

HMAC protects against post-session accidental or agent-initiated tampering, not
against a malicious operator with host access. For that, ship logs to an external
system. This is defense-in-depth, not a single guarantee.

**Is carranca competing with gVisor, Kata, Firecracker, or eBPF?**

Not directly. Carranca is a higher-level agent workflow layer: it manages
session policy, audit evidence, and operator controls around agent execution.
gVisor, Kata Containers, and Firecracker are stronger isolation substrates.
eBPF is a kernel technology for observability and enforcement. Those tools are
mostly complementary to Carranca rather than interchangeable with it.
