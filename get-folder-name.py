#!/usr/bin/python
# -*- coding: utf-8; indent-tabs-mode: nil -*-

import MAPI
MAPI.unicode = True
from MAPI.Util import *
from MAPI.Struct import *
from MAPI.Tags import *

import locale
import sys
import string
import time
import getopt

def main(argv):
	user = ''
	try:
		opts, args = getopt.getopt(argv,"hu:",["user="])
	except getopt.GetoptError:
		print 'get-folder-name.py -u <user>'
		sys.exit(2)
	for opt, arg in opts:
		if opt == '-h':
			print 'get-folder-name.py -u <user>'
			sys.exit()
		elif opt in ("-u", "--user"):
			user = arg

	if not user:
		print 'get-folder-name.py -u <user>'
		exit()

	session = OpenECSession(user, 'notused', 'file:///var/run/zarafa', flags = 0)

	store = GetDefaultStore(session)
	props = store.GetProps([PR_DISPLAY_NAME], 0)
	result = store.GetReceiveFolder('IPM', 0)
	inboxid = result[0]
	inbox = store.OpenEntry(inboxid, None, 0)

	tasksid = inbox.GetProps([PR_IPM_TASK_ENTRYID], 0)[0].Value
	tasks= store.OpenEntry(tasksid, None, 0)
	props = tasks.GetProps([PR_DISPLAY_NAME], 0)
	print 'TASKS ' + props[0].Value

	contactsid = inbox.GetProps([PR_IPM_CONTACT_ENTRYID], 0)[0].Value
	contacts = store.OpenEntry(contactsid, None, 0)
	props = contacts.GetProps([PR_DISPLAY_NAME], 0)
	print 'CONTACTS ' + props[0].Value

	contactsid = inbox.GetProps([PR_IPM_APPOINTMENT_ENTRYID], 0)[0].Value
	contacts = store.OpenEntry(contactsid, None, 0)
	props = contacts.GetProps([PR_DISPLAY_NAME], 0)
	print 'CALENDAR ' + props[0].Value

if __name__ == "__main__":
   main(sys.argv[1:])
