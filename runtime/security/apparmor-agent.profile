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

  # Allow read access broadly
  / r,
  /** r,

  # Allow execution of common tools
  /usr/bin/** ix,
  /usr/local/bin/** ix,
  /bin/** ix,
  /sbin/** ix,

  # Allow writes only to expected writable paths
  /tmp/** rw,
  /var/tmp/** rw,
  /run/** rw,
  /workspace/** rw,
  /fifo/** rw,
  /home/carranca/** rw,

  # Deny dangerous operations
  deny mount,
  deny umount,
  deny pivot_root,
  deny ptrace,
  deny signal (send) peer=unconfined,

  # Deny access to sensitive host paths
  deny /proc/*/mem rw,
  deny /proc/sysrq-trigger rw,
  deny /sys/firmware/** rw,
}
