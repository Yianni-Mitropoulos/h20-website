echo 'Ensuring logs are redirected to RAM and purged on shutdown'
until sudo mount -t tmpfs -o size=100M,mode=0755 tmpfs /var/log; do sleep 1; done

echo 'Recreating essential /var/log files and directories (tmpfiles.d)'
until sudo tee /etc/tmpfiles.d/h20-var-log.conf > /dev/null &lt;&lt;'EOF'
# h20-var-log.conf — recreate essentials when /var/log is tmpfs
d /var/log               0755 root root -
d /var/log/apt           0755 root root -
d /var/log/dpkg          0755 root root -
d /var/log/fsck          0755 root root -
d /var/log/rsyslog       0755 root root -
d /var/spool/rsyslog     0755 root root -
# classic login/accounting files
f /var/log/wtmp          0664 root utmp -
f /var/log/btmp          0600 root utmp -
f /var/log/lastlog       0644 root root -
f /var/log/faillog       0644 root root -
EOF
do sleep 1; done
until sudo systemd-tmpfiles --create /etc/tmpfiles.d/h20-var-log.conf; do sleep 1; done

echo 'Persist the mount in /etc/fstab (no idempotency, just append)'
until sudo tee -a /etc/fstab > /dev/null &lt;&lt;'EOF'
tmpfs /var/log tmpfs defaults,size=100m,mode=0755 0 0
EOF
do sleep 1; done

echo 'Configure systemd-journald to use volatile (RAM-only) logging'
until sudo mkdir -p /etc/systemd/journald.conf.d; do sleep 1; done
until sudo tee /etc/systemd/journald.conf.d/volatile.conf > /dev/null &lt;&lt;'EOF'
[Journal]
Storage=volatile
EOF
do sleep 1; done

echo 'Restarting journald to apply the volatile logging config'
until sudo systemctl restart systemd-journald; do sleep 1; done
if systemctl list-unit-files --no-legend --type=service 2>/dev/null | awk '{print $1}' | grep -Fxq rsyslog.service; then
  echo 'Restarting rsyslog to resync with journald and /var/log'
  until sudo systemctl restart rsyslog; do sleep 1; done
fi

echo 'Commenting out HIST or shopt lines in /etc/skel/.bashrc'
until sudo awk -v h="#" -f - /etc/skel/.bashrc > "/tmp/.h20.bashrc.new" &lt;&lt;'EOF'
/^[[:space:]]*(HIST|shopt)/ {
    sub(/^[[:space:]]*/, "&" h " ")
}
{ print }
EOF
do sleep 1; done
until sudo mv /tmp/.h20.bashrc.new /etc/skel/.bashrc; do sleep 1; done

echo 'Ensuring bash history is limited to 10 commands, stored in RAM, and purged on shutdown'
until sudo tee -a /etc/bash.bashrc > /dev/null &lt;&lt;'EOF'
export HISTSIZE=10
export HISTFILESIZE=0
export HISTFILE=/dev/null
EOF
do sleep 1; done

echo 'Creating root helper for h20-enable-journald'
until sudo tee /usr/sbin/h20-enable-journald-root > /dev/null &lt;&lt;'EOF'
#!/bin/sh
# h20-enable-journald-root
# ------------------------
# Unmasks, enables, and starts journald sockets/services, and rsyslog if present.
echo "[h20] enabling journald sockets/services"
for u in systemd-journald.socket systemd-journald-dev-log.socket systemd-journald-audit.socket systemd-journald.service; do
  if systemctl list-unit-files --no-legend --type=service --type=socket 2>/dev/null | awk '{print $1}' | grep -Fxq "$u"; then
    if systemctl is-enabled "$u" 2>&1 | grep -q masked; then
      echo "[h20] unmask $u"
      until systemctl unmask "$u"; do sleep 1; done
    fi
    echo "[h20] enable $u"
    until systemctl enable "$u"; do sleep 1; done
    echo "[h20] start $u"
    until systemctl start "$u" || systemctl restart "$u"; do sleep 1; done
  else
    echo "[h20] skip missing $u"
  fi
done
if command -v rsyslogd >/dev/null 2>&1 || [ -f /usr/sbin/rsyslogd ] || [ -f /usr/bin/rsyslogd ]; then
  echo "[h20] ensuring rsyslog.service is up"
  if systemctl is-enabled rsyslog.service 2>&1 | grep -q masked; then
    until systemctl unmask rsyslog.service; do sleep 1; done
  fi
  until systemctl enable rsyslog.service; do sleep 1; done
  until systemctl start rsyslog.service || systemctl restart rsyslog.service; do sleep 1; done
else
  echo "[h20] rsyslog not installed; skipping"
fi
echo "[h20] journald enable complete"
EOF
do sleep 1; done
until sudo chmod 0755 /usr/sbin/h20-enable-journald-root; do sleep 1; done
until sudo chown root:root /usr/sbin/h20-enable-journald-root; do sleep 1; done

echo 'Creating root helper for h20-disable-journald'
until sudo tee /usr/sbin/h20-disable-journald-root > /dev/null &lt;&lt;'EOF'
#!/bin/sh
# h20-disable-journald-root
# -------------------------
# Stops and disables journald sockets/services; stops/disables rsyslog if present.
echo "[h20] stopping journald sockets/services"
for u in systemd-journald.service systemd-journald.socket systemd-journald-dev-log.socket systemd-journald-audit.socket; do
  if systemctl list-unit-files --no-legend --type=service --type=socket 2>/dev/null | awk '{print $1}' | grep -Fxq "$u"; then
    until systemctl stop "$u" || systemctl try-restart "$u"; do sleep 1; done
    until systemctl disable "$u"; do sleep 1; done
  fi
done
if systemctl list-unit-files --no-legend --type=service 2>/dev/null | awk '{print $1}' | grep -Fxq rsyslog.service; then
  until systemctl stop rsyslog.service || systemctl try-restart rsyslog.service; do sleep 1; done
  until systemctl disable rsyslog.service; do sleep 1; done
fi
echo "[h20] journald mostly disabled"
EOF
do sleep 1; done
until sudo chmod 0755 /usr/sbin/h20-disable-journald-root; do sleep 1; done
until sudo chown root:root /usr/sbin/h20-disable-journald-root; do sleep 1; done

echo 'Creating root helper for h20-enable-log-exfil'
until sudo tee /usr/sbin/h20-enable-log-exfil-root > /dev/null &lt;&lt;'EOF'
#!/bin/sh
# h20-enable-log-exfil-root
# -------------------------
# Configures rsyslog to forward all logs to host "logaudit" over UDP 514.
AUDIT_HOST="logaudit"
AUDIT_PORT="514"
# install rsyslog if missing
if ! command -v rsyslogd >/dev/null 2>&1 && [ ! -f /usr/sbin/rsyslogd ] && [ ! -f /usr/bin/rsyslogd ]; then
  echo "[h20] installing rsyslog"
  until apt-get update; do sleep 1; done
  until DEBIAN_FRONTEND=noninteractive apt-get install -y rsyslog; do sleep 1; done
fi
# ensure imjournal follows journald
if [ -f /etc/rsyslog.conf ]; then
  if ! grep -q '^module(load="imjournal")' /etc/rsyslog.conf; then
    echo '[h20] enabling imjournal in /etc/rsyslog.conf'
    until sed -i '1imodule(load="imjournal" StateFile="/var/spool/rsyslog/imjournal.state")' /etc/rsyslog.conf; do sleep 1; done
  fi
fi
# forward everything
until mkdir -p /etc/rsyslog.d; do sleep 1; done
until tee /etc/rsyslog.d/99-h20-forward-all.conf >/dev/null &lt;&lt;EOC
# h20 forward all logs to logaudit
*.*  @${AUDIT_HOST}:${AUDIT_PORT}
EOC
do sleep 1; done
# start/enable rsyslog
if systemctl is-enabled rsyslog.service 2>&1 | grep -q masked; then
  until systemctl unmask rsyslog.service; do sleep 1; done
fi
until systemctl enable rsyslog.service; do sleep 1; done
until systemctl restart rsyslog.service; do sleep 1; done
echo "[h20] log exfil enabled to ${AUDIT_HOST}:${AUDIT_PORT}"
EOF
do sleep 1; done
until sudo chmod 0755 /usr/sbin/h20-enable-log-exfil-root; do sleep 1; done
until sudo chown root:root /usr/sbin/h20-enable-log-exfil-root; do sleep 1; done

echo 'Creating root helper for h20-disable-log-exfil'
until sudo tee /usr/sbin/h20-disable-log-exfil-root > /dev/null &lt;&lt;'EOF'
#!/bin/sh
# h20-disable-log-exfil-root
# --------------------------
# Removes the rsyslog forwarding config and restarts rsyslog.
if [ -f /etc/rsyslog.d/99-h20-forward-all.conf ]; then
  until rm -f /etc/rsyslog.d/99-h20-forward-all.conf; do sleep 1; done
fi
if systemctl list-unit-files --no-legend --type=service 2>/dev/null | awk '{print $1}' | grep -Fxq rsyslog.service; then
  until systemctl restart rsyslog.service; do sleep 1; done
fi
echo "[h20] log exfil disabled"
EOF
do sleep 1; done
until sudo chmod 0755 /usr/sbin/h20-disable-log-exfil-root; do sleep 1; done
until sudo chown root:root /usr/sbin/h20-disable-log-exfil-root; do sleep 1; done

echo 'Allowing passwordless enablement of log creation and log exfil'
until sudo tee /etc/sudoers.d/h20-logs > /dev/null &lt;&lt;'EOF'
Cmnd_Alias H20_ENABLES = /usr/sbin/h20-enable-journald-root, /usr/sbin/h20-enable-log-exfil-root
user ALL=(root) NOPASSWD: H20_ENABLES
Defaults!H20_ENABLES env_reset,secure_path="/usr/sbin:/usr/bin:/sbin:/bin"
EOF
do sleep 1; done
until sudo chmod 0440 /etc/sudoers.d/h20-logs; do sleep 1; done
until sudo visudo -c > /dev/null; do sleep 1; done

echo 'Creating bash wrappers for exposure to end-user'
until sudo tee -a /etc/bash.bashrc > /dev/null &lt;&lt;'EOF'
# h20-enable-journald
# -------------------
# Turns system logging on. Unmasks/enables/starts journald sockets/services,
# and ensures rsyslog is running if present. Can be run by non-root user
# due to a limited sudoers rule.
h20-enable-journald() {
  until sudo /usr/sbin/h20-enable-journald-root; do sleep 1; done
}

# h20-disable-journald
# --------------------
# Turns most system logging off. Stops/disables journald sockets/services
# and stops/disables rsyslog if present. Requires root/sudo privileges.
h20-disable-journald() {
  until sudo /usr/sbin/h20-disable-journald-root; do sleep 1; done
}

# h20-enable-log-exfil
# --------------------
# Forwards all logs to the "logaudit" host over UDP 514 via rsyslog.
# Installs rsyslog if missing. Can be run without a password due to
# a limited sudoers rule.
h20-enable-log-exfil() {
  until sudo /usr/sbin/h20-enable-log-exfil-root; do sleep 1; done
}

# h20-disable-log-exfil
# ---------------------
# Disables forwarding by removing the rsyslog snippet and restarting rsyslog.
# Requires root/sudo privileges.
h20-disable-log-exfil() {
  until sudo /usr/sbin/h20-disable-log-exfil-root; do sleep 1; done
}

# h20-watch-logs
# --------------
# Shows the last 200 journal lines and then follows new log entries in realtime.
# Must be run as root or with sudo.
h20-watch-logs() {
  sudo journalctl -n 200 -f --no-hostname --output=short-iso
}
EOF
do sleep 1; done

echo 'Installing 1-minute journal vacuum service and timer'
until sudo tee /etc/systemd/system/h20-journal-vacuum.service > /dev/null &lt;&lt;'EOF'
[Unit]
Description=H2O - vacuum systemd journal to 1 minute

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'journalctl --vacuum-time=1m || true'
EOF
do sleep 1; done

until sudo tee /etc/systemd/system/h20-journal-vacuum.timer > /dev/null &lt;&lt;'EOF'
[Unit]
Description=H2O - run journal vacuum every minute

[Timer]
OnBootSec=30s
OnUnitActiveSec=60s
Unit=h20-journal-vacuum.service
AccuracySec=10s

[Install]
WantedBy=timers.target
EOF
do sleep 1; done

echo 'Enabling and starting the 1-minute journal vacuum timer'
until sudo systemctl daemon-reload; do sleep 1; done
until sudo systemctl enable h20-journal-vacuum.timer; do sleep 1; done
until sudo systemctl start h20-journal-vacuum.timer; do sleep 1; done
