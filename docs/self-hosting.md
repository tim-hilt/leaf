# Self-hosting Cloud Backing

Any WebDAV server reachable over `https://` works. On a Raspberry Pi, `rclone` is enough:

    rclone serve webdav /srv/leaf --addr 127.0.0.1:8080 --user reader --pass change-me

As a service, `/etc/systemd/system/leaf-webdav.service` (then `systemctl enable --now leaf-webdav`):

    [Service]
    ExecStart=/usr/bin/rclone serve webdav /srv/leaf --addr :8080 --user reader --pass change-me
    Restart=always
    [Install]
    WantedBy=multi-user.target

Expose port 8080 over https with a [Cloudflare Tunnel](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/), then Connect in Settings with its URL, the user and the password. Leaf keeps everything in a `Leaf` folder inside.

If `cloudflared` runs in Docker, add `extra_hosts: ["host.docker.internal:host-gateway"]` to it, route the tunnel to `http://host.docker.internal:8080`, and apply with `docker compose up -d cloudflared` (`restart` ignores compose changes). Port 8080 is then open on your LAN; firewall it if untrusted devices share it.
