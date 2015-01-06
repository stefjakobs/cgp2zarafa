cgp2zarafa
==========

Tool set to migrate accounts from CommuniGate Pro (5.3.X) to Zarafa (7.1.X)

CommunigatePro Import scripts
-----------------------------

This toolset makes it possible to directly import data from a CommuniGate
Pro Environment to Zarafa and is entirely multi-server capable.

This toolset provides the current functionality to import:

- Calendar
- Contacts
- Tasks
- Permissions
- Rules (most of them)
- Notes
- E-Mail (All Folders which are not identified as ones above)

NOTE: cgp-migrate.sh can run parallelized, although be aware of multiple
RAMDISK_SIZE usage from config.sh 
NOTE2: If you abort the script while running, please make sure to clean
out potentially still mounted RAMDISKs by using cgp-cleanup.sh

Please note that the MBOX-Import is not the best import-possibility, as it
is not structure-aware (subfolders). For E-Mails it is recommended to use
imapsync, of which an installation script is included: install-imapsync.sh

For the IMAPsync run we recommend to use the command structure:

imapsync --buffersize 8192000 --nosyncacls --syncinternaldates --nofoldersizes \
  --skipsize --fast --noauthmd5 --host1 old.server.tld --user1 old_user \
  --password1 old_password -sep2 / --prefix2 "" --host2 zarafa.server.tld \
  --user2 new_user --password2 new_password \
  --regextrans2 's/^Sent$/Gesendete Objekte/' \
  --regextrans2 's/^Drafts$/Entwürfe/' \
  --regextrans2 's/^Trash$/Gelöschte Objekte/'

By using the local_admin_users directive on the Zarafa Server (server.cfg)
you are not required to input a valid password during IMAP import.

### System Requirements:
- bash
- perl
- cscript
- sed
- curl
- python
- python-mapi
- zarafa-utils (and dependencies)
- zarafa-ical (on defined destination server)
- php5-mapi on apache2 (only on sabre-zarafa server)

### General Requirements:
- admin-user zarafa
- root access to all systems involved for installation of required components

### IMPORTANT NOTE: YOU SHOULD NOT RUN SABRE-ZARAFA ON A PRODUCTION SYSTEM,
###   AS THIS IS ONLY FOR IMPORT!
### REASON: TO IMPORT TO ANY STORE SABRE-ZARAFA REQUIRES IMPERSONATION
###   RIGHTS, ALLOWING ACCESS TO CONTACTS WITHOUT 'REAL' AUTHENTICATION

### Howto
1. Setup zarafa-sabre on a webserver of choice which has zarafa-server
   and socket available (file:///var/run/zarafa)
   - Copy the zarafa-sabre folder to like e.g. /usr/share/
   - Insert the webserver configuration to the webserver
   - Restart/reload webserver tousenew configuration
2. ONLY on that (zarafa-sabre) server, add the webserver-user,
      e.g. www-data to the parameter "local_admin_users" in server.cfg
   - Restart zarafa-server service
3. Configure the parameters in cgp-migrate.conf to match your environment
4. Make sure your migration server has $RAMDISK_SIZE (default: 1GB) RAM free! 
5. Run ./cgp-migrate.sh <fromuser without .macnt> <touser (zarafa)>
   from _this_ directory or change $TOOL_LOCATION accordingly 
