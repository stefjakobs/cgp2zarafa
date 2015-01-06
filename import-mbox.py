#!/usr/bin/python
# -*- coding: utf-8; indent-tabs-mode: nil -*-

import mailbox
import os
import sys

import MAPI
from MAPI.Util import *
import inetmapi

class ZStore:
    def __init__(self, username):
        try:
            self.session = OpenECSession(username, '', os.getenv('ZARAFA_SOCKET','file:///var/run/zarafa'))
        except MAPIError, e:
            print "[MAIL-IMPORT] Unable to login using %s" % username
            raise e
        self.abook = self.session.OpenAddressBook(0, None, MAPI_UNICODE)
        self.store = GetDefaultStore(self.session)
        eid = self.store.GetReceiveFolder('IPM', 0)[0]
        self.dest = self.inbox = self.store.OpenEntry(eid, None, MAPI_MODIFY)
        self.dopt = inetmapi.delivery_options()
        self.errors = 0

    def setDestFolder(self, foldername, foldertype):
        self.dest = self.inbox.CreateFolder(FOLDER_GENERIC, foldername, None, None, OPEN_IF_EXISTS)
        self.props = self.dest.SetProps([SPropValue(PR_CONTAINER_CLASS, unicode(foldertype, 'utf-8'))])
        self.errors = 0

    def addMessage(self, rfc):
        msg = self.dest.CreateMessage(None, 0)
        try:
            inetmapi.IMToMAPI(self.session, self.store, self.abook, msg, str(rfc), self.dopt)
        except:
            self.errors += 1
            return
        try:
            # mark as read when rfc['status'] contains R (mbox only)
            if 'R' in rfc['status']:
                msg.SetProps([SPropValue(PR_MESSAGE_FLAGS, MSGFLAG_READ)])
        except:
            pass
        msg.SaveChanges(0)
        

def main(argv = None):
    if argv is None:
        argv = sys.argv

    if len(argv) < 4:
        print argv[0] + " <username> <foldertype> <file> [file...]"
        sys.exit(1)

    name = argv[1]
    foldertype = argv[2]
    zstore = ZStore(name)

    if not foldertype in ["IPF.Appointment", "IPF.Contact", "IPF.StickyNote", "IPF.Task", "IPF.Note"] :
        print "foldertype must be one of 'IPF.{Contact,StickyNote,Task,Note,Appointment}'"
        sys.exit(1)

    for boxname in argv[3:]:
        if boxname[-1] == '/':
            boxname = boxname[:-1]
        print "[MAIL-IMPORT] Processing " + boxname
        try:
            if os.path.isdir(boxname):
                mbox = mailbox.Maildir(boxname)
            else:
                mbox = mailbox.mbox(boxname)
        except:
            print "[MAIL-IMPORT] Invalid object"
            continue
        
        if len(mbox) == 0:
            print "[MAIL-IMPORT] No mails in %s" % (boxname)
            continue

	if (os.path.basename(boxname)) != 'INBOX.mbox':
		zstore.setDestFolder(os.path.basename(boxname.rstrip('.mbox')), foldertype)

        errors = i = 0
        for m in mbox:
            i += 1
            try:
                if m['from'].startswith('Mail System Internal Data'):
                    continue
            except:
                pass
            try:
                zstore.addMessage(m)
            except:
                errors += 1
                continue
        print "[MAIL-IMPORT] %s imported %d messages with %d import errors, %d mapi errors" % (boxname, len(mbox), zstore.errors, errors)

if __name__ == '__main__':
    sys.exit(main())
