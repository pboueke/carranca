# AppArmor profile for carranca agent container
# Reference profile — not applied by default.
#
# To load:
#   sudo apparmor_parser -r /path/to/apparmor-agent.profile
#
# Then set in .carranca.yml:
#   runtime:
#     apparmor_profile: carranca-agent
#
# To unload:
#   sudo apparmor_parser -R /path/to/apparmor-agent.profile

#include <tunables/global>

profile carranca-agent flags=(attach_disconnected,mediate_deleted) {
  #include <abstractions/base>
  #include <abstractions/nameservice>

  # ── Deny rules ────────────────────────────────────────────────────
  # Block sensitive credential and security files before any allow
  # rules can match them.
  deny /etc/shadow r,
  deny /etc/gshadow r,
  deny /root/** rwx,

  # Prevent reading raw process memory, kernel core, and kernel logs.
  deny /proc/[0-9]*/mem rwx,
  deny /proc/kcore r,
  deny /proc/kmsg r,

  # Firmware and kernel-security interfaces are never needed by an agent.
  deny /sys/firmware/** rwx,
  deny /sys/kernel/security/** rwx,

  # Deny dangerous operations
  deny mount,
  deny umount,
  deny pivot_root,
  deny ptrace,
  deny signal (send) peer=unconfined,

  # ── Read-only paths ──────────────────────────────────────────────
  # Mounted project workspace
  /workspace/** r,

  # Shared libraries (needed by virtually every dynamically-linked binary)
  /usr/lib/** r,
  /usr/lib32/** r,
  /usr/lib64/** r,
  /lib/** r,
  /lib64/** r,
  /lib32/** r,

  # Dynamic linker configuration
  /etc/ld.so.cache r,
  /etc/ld.so.conf r,
  /etc/ld.so.conf.d/** r,

  # TLS certificates — required for HTTPS connections
  /etc/ssl/** r,
  /etc/ca-certificates/** r,
  /usr/share/ca-certificates/** r,

  # Network configuration (DNS, host resolution)
  /etc/resolv.conf r,
  /etc/hosts r,
  /etc/hostname r,
  /etc/nsswitch.conf r,

  # User/group databases (read-only; many tools call getpwuid/getgrgid)
  /etc/passwd r,
  /etc/group r,

  # Locale and timezone data
  /etc/locale/** r,
  /etc/localtime r,
  /usr/share/locale/** r,
  /usr/share/zoneinfo/** r,

  # Process-level info from procfs
  /proc/self/** r,
  /proc/sys/kernel/hostname r,
  /proc/sys/kernel/osrelease r,

  # Device nodes (null sink, zero source, entropy, fd/pts)
  /dev/null r,
  /dev/zero r,
  /dev/urandom r,
  /dev/random r,
  /dev/fd/** r,
  /dev/pts/** r,

  # Temp directories (read + write, see writable section below)
  /tmp/** r,
  /var/tmp/** r,

  # Broad read-only access to /usr/share (man pages, terminfo, misc data)
  /usr/share/** r,

  # Agent user home directory
  /home/carranca/** r,

  # ── Writable paths ──────────────────────────────────────────────
  # Temp and runtime directories
  /tmp/** w,
  /var/tmp/** w,
  /run/** rw,

  # Project workspace — the agent needs to create/edit files here
  /workspace/** w,

  # FIFO directory used for inter-process communication
  /fifo/** rw,

  # Agent home directory
  /home/carranca/** w,

  # ── Execute permissions ─────────────────────────────────────────
  # Common tool directories — inherit the current profile (ix)
  /usr/bin/** ix,
  /usr/local/bin/** ix,
  /bin/** ix,
  /sbin/** ix,

  # Shared libraries need mmap-read (mr) to be loaded by the linker
  /usr/lib/** mr,
}
