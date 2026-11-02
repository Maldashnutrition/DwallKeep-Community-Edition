# DwallKeep

A VPN + Tor chain manager with a desktop GUI. Two VPN hops with Tor between them.

## What this is

DwallKeep brings up an isolated systemd-nspawn container that routes your
traffic through entry VPN → Tor → exit VPN. It includes a desktop GUI for
starting the chain, opening Firefox and other apps inside the container,
and copying files between the container and the host.

## What this is not

- Not anonymous against a global adversary
- Not hardened to the same degree as the commercial build (see "Security posture")
- Not affiliated with VPNBook or VPNGate

## Requirements

- Debian or Ubuntu host (tested on Debian stable)
- `systemd-nspawn`, `mmdebstrap`, `python3`, `customtkinter`, `pillow`
- `sudo` configured to allow `nsenter` without a password for the GUI
  (see `SECURITY.md` for the sudoers snippet)

Install Python GUI dependencies:
pip install --user customtkinter pillow


## Quick start

chmod +x dwallkeep_backend.sh
sudo bash dwallkeep_backend.sh # builds rootfs on first run (~15 min)
python3 dwallkeep_frontend.py # launches the GUI


To stop the chain:

sudo bash dwallkeep_backend.sh --stop


## Cooldown and overrides

The community edition enforces a 15-minute cooldown between VPNBook chain
starts, with a rate-limited override (3 per 25 minutes). This exists because
VPNBook is a shared personal-use resource and rapid reconnection increases
the risk of an IP ban.

## Security posture

See `SECURITY.md` for the full threat model. Summary: this edition
prioritises installability; the commercial build adds private-user
namespaces, seccomp, AppArmor, read-only rootfs, and supply-chain pinning.

## Provider policies

VPNBook: "This free VPN service is for personal use only." They log
connection IPs and ban abusers. VPNGate is donation-funded. You are
responsible for complying with whichever provider you point this at.

## Commercial build

A hardened build with server-side integration is in development.
Contact for details.

## License

GNU General Public License v3.0. See `LICENSE`.
