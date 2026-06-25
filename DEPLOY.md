# Deploying the dedicated server to a VPS

The server is just the game exported for Linux, run with `--server`. Once it's on a
machine with a public IP, anyone can join it (no port-forwarding on your home router).

You can test **solo**: run the server on the VPS, then open two client windows on your
own PC and join the VPS IP — that's 2 players, so the round starts.

## 1. Export a Linux build (in Godot, on your PC)
1. `Editor → Manage Export Templates…` → Download (if not already installed for 4.6.3).
2. `Project → Export… → Add… → Linux`.
3. Set **Export Path** to `build/enders_server.x86_64`.
4. (Recommended) In the preset's **Options** tab, enable **Embed PCK** → single file to upload.
5. Click **Export Project**. You get `build/enders_server.x86_64` (+ a `.pck` if not embedded).

## 2. Rent a VPS
- Hetzner Cloud (~€4/mo), DigitalOcean / Vultr / Linode (~$5/mo). Smallest tier is fine.
- OS: **Ubuntu 24.04 LTS**.
- Note the **public IP** and your SSH login.
- In the provider's **cloud firewall**, allow inbound **UDP 7000**.

## 3. Upload the build (from Windows PowerShell)
```powershell
scp build\enders_server.x86_64 root@<VPS_IP>:/root/
scp run_server.sh             root@<VPS_IP>:/root/
# also upload the .pck if you did NOT embed it
```
(Or use the WinSCP GUI.)

## 4. Run it on the VPS
```bash
ssh root@<VPS_IP>
sudo apt update && sudo apt install -y tmux          # keeps the server alive
sudo ufw allow 7000/udp                              # if ufw is enabled
chmod +x enders_server.x86_64 run_server.sh
./run_server.sh 7000
tmux attach -t gameserver                            # should show "listening on port 7000"
# detach with Ctrl+B then D; the server keeps running
```
If the binary complains about a missing library, install whatever `.so` it names, e.g.
`sudo apt install -y libfontconfig1`.

## 5. Connect clients
On your PC, run the game → **Multiplayer → Join** → enter `<VPS_IP>` → **Join**.
Do it **twice** (two windows) → 2 players → the round starts. (Or have a friend join the
same IP.)

## Notes
- The client connect port is fixed at **7000** in code; players only type the IP.
- For a permanent always-on server, replace tmux with a **systemd service** later.
- Same default map as everyone (Designed) — don't change per-client until map-sync is added.
