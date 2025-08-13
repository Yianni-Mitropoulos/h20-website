sudo mkdir -p /etc/systemd/system.service.d && \
echo -e "[Service]\nProtectSystem=full\nReadWritePaths=/var/log" | sudo tee /etc/systemd/system.service.d/hardening.conf > /dev/null && \
sudo mount -t tmpfs -o size=100M tmpfs /var/log && \
echo 'tmpfs /var/log tmpfs defaults,size=100m 0 0' | sudo tee -a /etc/fstab > /dev/null && \
sudo systemctl daemon-reexec