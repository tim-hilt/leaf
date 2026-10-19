# Self-hosting Cloud Backing

Any WebDAV server reachable over `https://` works. On a Raspberry Pi, `rclone` is enough:

    rclone serve webdav /srv/leafpdf --addr 127.0.0.1:8080 --user reader --pass change-me

As a service, `/etc/systemd/system/leafpdf-webdav.service` (then `systemctl enable --now leafpdf-webdav`):

    [Service]
    ExecStart=/usr/bin/rclone serve webdav /srv/leafpdf --addr 127.0.0.1:8080 --user reader --pass change-me
    Restart=always
    [Install]
    WantedBy=multi-user.target

Expose port 8080 over https with a [Cloudflare Tunnel](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/), then Connect in Settings with its URL, the user and the password. LeafPDF keeps everything in a `LeafPDF` folder inside.
