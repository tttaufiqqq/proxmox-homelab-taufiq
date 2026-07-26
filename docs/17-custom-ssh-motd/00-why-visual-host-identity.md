# Why This Series Exists

Every VM/CT in this homelab is reachable over SSH under its own alias, and
by the time the fleet grew past a dozen hosts it stopped being obvious,
at a glance, which one a given terminal tab was actually connected to. The
hostname is always there in the prompt text, but a wall of terminal tabs
all showing white-on-black text doesn't let you tell them apart without
actually reading each one.

The fix ended up being two separate, complementary pieces, each solving a
different moment of an SSH session:

- **The login banner** — the first thing you see, once, when you connect.
- **The live prompt** — on screen for every command after that, for the
  rest of the session.

Both use the same underlying idea: give every host a fixed, distinct color
tied to its identity, so the *color* is the signal, not just the hostname
text. Both docs below reuse the exact same per-host color mapping, so a
host's login banner and its prompt always agree with each other.

## What's in this series

| # | Doc | Covers |
|---|---|---|
| 01 | [Custom SSH login banner (dynamic MOTD)](01-custom-ssh-motd-setup.md) | A per-role, per-host-colored figlet banner shown once at login, with live stats and a service health check, rolled out to all 13 original VMs/CTs plus a fastfetch-based equivalent for the `taufiq` host node itself |
| 02 | [Oh My Posh per-host prompt themes](02-oh-my-posh-theme-setup.md) | A rounded-pill oh-my-posh prompt, colored per host to match doc 01's mapping, staying on screen for the whole session instead of just at login — extended to cover `linux-k3s`, `linux-observability`, and `taufiq` too, which postdate doc 01's original rollout |
