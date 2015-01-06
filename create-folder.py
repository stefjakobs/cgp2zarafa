#!/usr/bin/python
# -*- coding: utf-8; indent-tabs-mode: nil -*-

# Copyright (C) 2014
# Stefan Jakobs <projects AT localside.net>
# Michael Kromer <m.kromer AT zarafa.com>
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

import os
import locale
import sys
import string
import time
import getopt

try:
	import MAPI
	from MAPI.Util import *
	MAPI.unicode = True
except ImportError, e:
	print "Not all modules can be loaded. The following modules are required:"
	print "- MAPI (Zarafa)"
	print ""
	print e
	sys.exit(1)

def print_help():
	print "Usage: %s -u [username of mailbox] -f [folder/name]" % sys.argv[0]
	print ""
	print "Create folder in MAPI Store"
	print ""
	print "Required arguments:"
	print "   -u, --user          User to set forwarding rule"
	print "   -f, --folder        Create this folder; hierarchies are separated by /"
	print ""
	print "optional arguments:"
	print "   -t, --type          Create folder of the named type; possible values:"
	print "                         IPF.{Appointment,Contact,StickyNote,Task,Note}"
	print "                         Default: IPF.Note (= Mailfolder)"
	print "   -h, --host          Host to connect with. Default: file:///var/run/zarafa"
	print "   -s, --sslkey-file   SSL key file to authenticate as admin. Default: /etc/zarafa/ssl/client.pem"
	print "   -p, --sslkey-pass   Password for the SSL key file."
	print "   --help              Show this help message and exit."

argv = sys.argv

def create_folder(store, basefolder, foldername, foldertype, pos):
	folderelements = len(foldername)-1
	found = 0
	newfolder = ''

	#basefolder = store.OpenEntry(entryid, None, MAPI_BEST_ACCESS | MAPI_UNICODE)
	table = basefolder.GetHierarchyTable(MAPI_UNICODE)
	table.SetColumns([CHANGE_PROP_TYPE(PR_DISPLAY_NAME, PT_UNICODE), PR_ENTRYID, PR_CONTAINER_CLASS], 0)
	rows = table.QueryRows(1000,0)
	for row in rows:
		if row[0].Value == foldername[pos] and row[2].Value == foldertype:
			found = 1
			newfolder = store.OpenEntry(row[1].Value, None, MAPI_BEST_ACCESS | MAPI_UNICODE)
	if found == 0:
		try:
			newfolder = basefolder.CreateFolder(FOLDER_GENERIC, foldername[pos], u'', None, MAPI_UNICODE)
			try:
				newfolder.SetProps([SPropValue(PR_CONTAINER_CLASS, foldertype)])
			except:
				print "SetProps error"
			print "[     CREATE] Folder: "  + foldername[pos] +" (" + foldertype +")"
		except MAPIError, err:
			if err.hr == MAPI_E_COLLISION:
				print "Warning: Folder exists already."
			else:
				print "Error: Unexpected MAPI error occurred. hr=0x%08x" % err.hr
				return 1
		except:
			print "Unexpected error occurred."
			return 1
	if pos != folderelements and newfolder != '':
		pos += 1
		create_folder(store, newfolder, foldername, foldertype, pos);
	
	return

def main(argv = None):
	if argv is None:
		argv = sys.argv

	try:
		opts, args = getopt.gnu_getopt(argv, 'h:f:p:s:t:u:', ['host=', 'folder=', 'sslkey-pass=', 'sslkey-file=', 'user=', 'type=', 'help'])
	except getopt.GetoptError, err:
		# print help information and exit:
		print str(err)
		print ""
		print_help()
		return 1

	host = 'file:///var/run/zarafa'
	sslkey_file = '/etc/zarafa/ssl/client.pem'
	sslkey_pass = None
	username = None
	foldername = None
	foldertype = 'IPF.Note'

	for o, a in opts:
		if o in ('-f', '--folder'):
			foldername = unicode(a, 'utf-8').split('/')
		elif o in ('-u', '--user'):
			username = a
		elif o in ('-t', '--type'):
			foldertype = unicode(a, 'utf-8')
		elif o in ('-h', '--host'):
			host = a
		elif o in ('-s', '--sslkey-file'):
			sslkey_file = a
		elif o in ('-p', '--sslkey-pass'):
			sslkey_pass = a
		elif o == '--help':
			print_help()
			return 0
		else:
			assert False, ("unhandled option '%s'" % o)

	if not foldername:
		print "No foldername specified."
		print ""
		print_help()
		sys.exit(1)

	if not username:
		print "No username specified."
		print ""
		print_help()
		sys.exit(1)

	# If there is a key file zarafa will ask for the passwort,
	# therefore empty sslkey_file
	if host.startswith('file://'):
		sslkey_file = None

	if foldertype == "IPF.Appointment":
		seekprop = [PR_IPM_APPOINTMENT_ENTRYID]
	elif foldertype == "IPF.Contact":
		seekprop = [PR_IPM_CONTACT_ENTRYID]
	elif foldertype == "IPF.StickyNote":
		seekprop = [PR_IPM_NOTE_ENTRYID]
	elif foldertype == "IPF.Task":
		seekprop = [PR_IPM_TASK_ENTRYID]
	elif foldertype == "IPF.Note":
		seekprop = [PR_ENTRYID]
	else:
		print "foldertype must be one of 'IPF.{Contact,StickyNote,Task,Note,Appointment}'"
		sys.exit(1)

	try:
		session = OpenECSession(username, '', host, sslkey_file = sslkey_file, sslkey_pass = sslkey_pass)
		store = GetDefaultStore(session)
		inboxeid = store.GetReceiveFolder('IPM', 0)[0]
		inbox = store.OpenEntry(inboxeid, None, MAPI_BEST_ACCESS | MAPI_UNICODE)
	except MAPIError, err:
		if err.hr == MAPI_E_LOGON_FAILED:
			 print "Failed to logon. Make sure your credentials are correct."
		elif err.hr == MAPI_E_NETWORK_ERROR:
			 print "Unable to connect to server. Make sure you specified the correct server."
		else:
			 print "Unexpected error occurred. hr=0x%08x" % err.hr
		sys.exit(1)

	ipm = inbox.GetProps(seekprop, 0)[0].Value
	basefolder = store.OpenEntry(ipm, None, MAPI_BEST_ACCESS | MAPI_UNICODE)

	create_folder(store, basefolder, foldername, foldertype, 0)

#if len(argv) < 2:
#	print argv[0] + " <username> <folder>[/<folder>[..]] <foldertype>"
#	sys.exit(1)

#username = argv[1]
#foldername = argv[2].split('/')
#foldertype = argv[3]

#session = OpenECSession(username, 'notused', 'file:///var/run/zarafa', flags = 0)
#store = GetDefaultStore(session)
#result = store.GetReceiveFolder('IPM', 0)
#inboxid = result[0]
#inbox = store.OpenEntry(inboxid, None, 0)

#if foldertype == "IPF.Appointment":
#	seekprop = [PR_IPM_APPOINTMENT_ENTRYID]
#elif foldertype == "IPF.Contact":
#	seekprop = [PR_IPM_CONTACT_ENTRYID]
#elif foldertype == "IPF.StickyNote":
#	seekprop = [PR_IPM_NOTE_ENTRYID]
#elif foldertype == "IPF.Task":
#	seekprop = [PR_IPM_TASK_ENTRYID]
#else:
#	seekprop = [PR_ENTRYID]

#ipm = inbox.GetProps(seekprop, 0)[0].Value
#basefolder = store.OpenEntry(ipm, None, MAPI_BEST_ACCESS)

#create_folder(basefolder, foldername, 0)


#table = basefolder.GetHierarchyTable(0)
#table.SetColumns([PR_DISPLAY_NAME, PR_ENTRYID], 0)
#rows = table.QueryRows(1000,0)
#for row in rows:
#	if row[0].Value == foldername[0]:
#		print row[0].Value +'\n'
#		folder = basefolder.OpenEntry(row[1].Value, None, MAPI_BEST_ACCESS)
#		table = folder.GetHierarchyTable(0)
#		table.SetColumns([PR_DISPLAY_NAME, PR_ENTRYID], 0)
#		frows = table.QueryRows(1000,0)
#		for frow in frows:
#			print frow[0].Value


#try:
#	newfolder = basefolder.CreateFolder(FOLDER_GENERIC, foldername, '', None, 0)
#	newfolder.SetProps([SPropValue(PR_CONTAINER_CLASS, unicode(foldertype, 'utf-8'))])
#except:
#	print "Unexpected error: Folder already exists?", foldername

if __name__ == '__main__':
	sys.exit(main())
