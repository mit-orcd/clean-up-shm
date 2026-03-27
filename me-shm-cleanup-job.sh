DRY_RUN=1
MAILTO=""
SHELL=/bin/bash
PATH=/usr/sbin:/usr/bin:/sbin:/bin

17 * * * * /usr/local/sbin/me-shm-cleanup.sh >> /var/log/me-shm-cleanup.log 2>&1
