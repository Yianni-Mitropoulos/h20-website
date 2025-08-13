# Step 1: Remove existing logrotate cron job from /etc/cron.daily
until rm -f /etc/cron.daily/logrotate; do sleep 1; done

# Step 2: Create a 5-minute logrotate cron job in /etc/cron.d/logrotate
until echo "*/5 * * * * root /usr/sbin/logrotate /etc/logrotate.conf" > /etc/cron.d/logrotate; do sleep 1; done

# Step 3: Create the logclear.sh script
until mkdir -p /etc/cron.logclear; do sleep 1; done
until cat <<'EOF' > /etc/cron.logclear/logclear.sh
#!/bin/bash

# Find and remove logs older than 15 minutes in /var/log/
find /var/log/ -type f -mmin +15 -exec rm -f {} \;
EOF
do sleep 1; done

# Step 4: Create the logclear cron job to run every 5 minutes
until echo "*/5 * * * * root /etc/cron.logclear/logclear.sh" > /etc/cron.d/logclear; do sleep 1; done

# Step 5: Set appropriate permissions
until chmod +x /etc/cron.logclear/logclear.sh; do sleep 1; done
until chmod 644 /etc/cron.d/logclear; do sleep 1; done
until chmod 644 /etc/cron.d/logrotate; do sleep 1; done

# Report that the jobs were added
echo "Cron jobs added successfully!"
