# Security Policy

## Reporting a vulnerability

Email: <ntengintengi28@gmail.com>

Please do not open public issues for security vulnerabilities.
I aim to acknowledge reports within 72 hours.

## Supported versions

Only the latest release receives security fixes.

## Scope and threat model

This is the **community edition** of DwallKeep. It prioritises ease of
installation over the full isolation profile of the commercial build.

Known limitations in this edition:

- The container runs without `--private-users=pick`. Container UID 0 maps
  to host UID 0. A container breakout yields host root with the container's
  capability set.
- Host `/dev/shm` is bound into the container.
- `xhost +local:` is enabled while the GUI is running.
- No seccomp, AppArmor, or read-only rootfs in this build.

Do not run this on a multi-user host. The commercial build addresses
these limitations.

## Out of scope

- VPNBook or VPNGate provider-side outages or bans.
- Anonymity against a global passive adversary. Tor does not provide that
  on its own.
- Abuse of the tool against provider terms of service.
