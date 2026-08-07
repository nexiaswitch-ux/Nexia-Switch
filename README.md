# NEXIA Switch

**Self-hosted Class 4 VoIP softswitch** — wholesale call routing (LCR), SIP
admission, media, and real-time billing, built on Kamailio + FreeSWITCH +
rtpengine, with a web administration panel.

> ⚠️ **Proprietary software.** This repository is the official **download
> surface**. The source code is **not** public. You may **download and
> install** NEXIA Switch, but you may **not modify, redistribute, or reverse
> engineer it**. See the [LICENSE](LICENSE).

---

## Download

Official builds are published on the **[Releases](../../releases)** tab of this
repository. Each Release includes:

- the signed installer,
- checksums (SHA-256),
- the release notes.

> Releases are the **only** supported distribution source. Do not download
> NEXIA Switch from anywhere else.

## Installation

Download the bootstrap, **read it**, and run it as root. It downloads the
latest signed release bundle, verifies its Ed25519 signature against a key
pinned inside the bootstrap itself, and only then installs:

```bash
curl -fsSLO https://raw.githubusercontent.com/nexiaswitch-ux/Nexia-Switch/main/install.sh
less install.sh          # read it before you run it — it installs as root
sudo bash install.sh
```

> **Do not pipe `curl … | bash`.** The bootstrap is short and written to be
> read. It never installs anything whose signature does not verify.

Useful options:

```bash
# Pin a specific version
sudo NEXIA_VERSION=1.0.0 bash install.sh

# Download and verify only, then inspect before installing
sudo NEXIA_FETCH_ONLY=1 bash install.sh

# Install with a domain and issue a real TLS certificate automatically
sudo NEXIA_DOMAIN=voice.example.com NEXIA_ADMIN_EMAIL=admin@example.com bash install.sh
```

Prerequisites (summary):

- A dedicated Linux server (Debian/Ubuntu recommended), `root` access.
- A public IP and available telephony ports (SIP/RTP).
- A valid license issued for your server.

## Support and commercial licenses

For licensing, support, or distribution/modification permissions, contact the
rights holder. Any modification or redistribution requires prior written
authorization.

---

© 2026 NEXIA Switch. All rights reserved.
