# vps-init

Bootstrap a fresh Debian 13 VPS into a homelab DR standby node with a single command.

## Prerequisites

Before running `init.sh` you need:

1. **UDM Pro WireGuard server running** with the VPS added as a peer
2. **Client config exported** from UniFi Console → VPN → WireGuard
3. **SSH public key** from 1Password ready to paste
4. **home.rammos.family** resolving to your home public IP

## UDM WireGuard Setup

In UniFi Console:

1. Go to **Settings → VPN → WireGuard**
2. Create a WireGuard server if one doesn't exist
3. Add a client — name it `vps-dr`
4. Set `AllowedIPs = 0.0.0.0/0` on the client (so all VPS traffic routes home)
5. Export the client config — it will look like:

```ini
[Interface]
PrivateKey = <generated>
Address = 10.100.0.x/24
DNS = 10.0.0.3, 10.0.0.2, 1.1.1.1

[Peer]
PublicKey = <udm public key>
Endpoint = home.rammos.family:<port>
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
```

Note: if the exported config is missing `AllowedIPs` or has a different value, `init.sh` will inject/replace it automatically.

## Running the Init Script

On the fresh VPS (as root):

```bash
apt-get install -y curl
curl -fsSL https://raw.githubusercontent.com/pyRammos/vps-init/main/init.sh | bash
```

Or after cloning the repo:

```bash
sudo bash init.sh
```

The script will interactively ask you to:
- Paste your SSH public key (from 1Password)
- Paste your WireGuard client config (from UDM)
- Confirm before starting WireGuard (point of no return)

## What Gets Installed

| Component | Details |
|---|---|
| User | george, uid 1000, gid 100, sudo, docker group |
| SSH | Key-only auth, root login disabled, fail2ban |
| Docker | Official Docker CE + compose plugin |
| WireGuard | Client to UDM, full tunnel (all traffic via home) |
| Watchdog | Checks tunnel every 2min, restores internet on failure |

## WireGuard Watchdog

The watchdog protects against being permanently locked out if the tunnel breaks:

- Pings `10.0.0.99` (OMV) every 2 minutes via the tunnel
- After 3 consecutive failures: brings WireGuard down, restores direct internet
- Sends a Pushover alert (once `dr.conf` is populated with credentials)
- After 30 minutes: automatically restarts WireGuard and tries again
- This gives you a 30-minute SSH window on the public IP to diagnose and fix

## After Init — DR Setup

Once `init.sh` completes:

```bash
su - george
sudo bash ~/homelab/dr/setup-vps.sh
```

## Recovery — If You Get Locked Out Before the Watchdog Fires

1. Use Kimsufi's rescue mode (boot into rescue OS from the control panel)
2. Mount the VPS disk and edit `/etc/wireguard/wg0.conf`
3. Change `AllowedIPs = 0.0.0.0/0` to `AllowedIPs = 10.0.0.0/24, 10.100.0.0/24`
4. Reboot normally — VPS will have direct internet + home LAN tunnel only
