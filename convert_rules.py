import glob
import os.path
import sys
import traceback

import zarafa
import tempfile

from MAPI.Util import *
from MAPI.Util.AddressBook import *
from datetime import *

import cgon

""" convert rules from communigate pro which can be expressed as webapp-compatible mapi rules """

TEST_ACCOUNT ='''
{
 Password = test-zarafa2;
 PasswordEncryption = clear;
 PWDAllowed = NO;
 RealName = user1;
 RequireAPOP = YES;
 Rules = (
    (1,subject_is_move,((Subject,is,"*banaan*")),(("Store in","Junk E-mail"),(Discard))),
    (2,from_is_move,((To,is,"*mark.dufour@gmail.com*")),(("Store in","taktak"),(Discard))),
    (3,fromname_is_move,(("'From' Name",is,"*Mark Dufour*")),(("Store in","Junk E-mail"),(Discard))),
    (4,and_is_delete,(("'From' Name",is,"*Mark Dufour*"),(Subject,is,"*banaan*")),((Discard))),
    (0,from_in_copy,((From,in,"*dufour*,*bananella*")),(("Store in","Junk E-mail"))),
    (0,subject_is_fwd,((Subject,is,"*banaan*")),(("Forward to",mark.dufour@gmail.com),(Discard))),
    (0,subject_is_redir,((Subject,is,"*banaan*")),(("Redirect to",mark.dufour@gmail.com),(Discard)))
 );
 UseAppPassword = YES;
 UseExtPassword = NO;
}'''

FWD_PRESERVE_SENDER = 1 # XXX move to python-mapi
FWD_DO_NOT_MUNGE_MSG = 2

class UnsupportedException(Exception):
    pass

def action_delete(store):
    storeid = store.prop(PR_STORE_ENTRYID).value
    targetid = store.wastebasket.entryid.decode('hex')
    return ACTION(ACTTYPE.OP_MOVE, 0x00000000, None, None, 0x00000000, actMoveCopy(storeid, targetid))

def action_forward(ab, flavor, email): # XXX always uses SMTP (instead of ZARAFA)
    return ACTION(ACTTYPE.OP_FORWARD, flavor, None, None, 0x0, actFwdDelegate([[
        SPropValue(PR_ENTRYID, ab.CreateOneOff(email, u'SMTP', email, MAPI_UNICODE)),
        SPropValue(PR_OBJECT_TYPE, MAPI_MAILUSER),
        SPropValue(PR_DISPLAY_NAME, email),
        SPropValue(PR_DISPLAY_TYPE, DT_MAILUSER),
        SPropValue(PR_EMAIL_ADDRESS, email),
        SPropValue(PR_SMTP_ADDRESS, email),
        SPropValue(PR_ADDRTYPE, u'SMTP'),
        SPropValue(PR_RECIPIENT_TYPE, MAPI_TO),
        SPropValue(PR_SEARCH_KEY, 'SMTP:%s\x00' % email.upper())
    ]]))

def restriction_fromto(proptag, term, address):
#    term = '.*' + term + '.*' , RELOP_RE?
    return SCommentRestriction(SPropertyRestriction(RELOP_EQ, proptag, SPropValue(0x00010102, term)), [
        SPropValue(0x60000003, MAPI_TO),
        SPropValue(0x00010102, term),
        SPropValue(0x0001001E, address),
        SPropValue(PR_DISPLAY_TYPE, DT_MAILUSER),
    ])

def process_condition(cond):
    field = cond[0]
    if field not in ('Subject', 'From', "'From' Name", 'Sender', 'To', 'Any Recipient', 'Any To or Cc', 'Cc', 'Each To or Cc'):
        if '@' in field: # XXX temporary fix
            raise UnsupportedException('unsupported condition (email address?)')
        else:
            raise UnsupportedException('unsupported condition: %s' % field)
    operator = cond[1]
    if operator not in ('is', 'in'):
         raise UnsupportedException('unsupported operator: %s' % operator)
    terms = cond[2].split(',')
    for term in terms:
        if '*' in term.strip('*'): # only support asterisks at the beginning/end
            raise UnsupportedException('asterisk used inside term (condition %s)' % field)
    terms = [term.strip('*') for term in terms]
    return field, operator, terms

nr_rules = nr_unsupported = nr_error = 0

def process_account(account, server, options):
    global nr_rules, nr_unsupported, nr_error

    ab = server.mapisession.OpenAddressBook(0, None, 0)
    gab = GetGab(server.mapisession)

    if options.verbose:
        print 'ACCOUNT:', account.get('RealName', u'').encode('utf-8')

    # authenticate as user:
    # user = server.user(options.auth_user) #server.user(account['RealName'])
    # authenticate as admin:
    user = server.user(options.users[0])
    inbox = user.store.inbox
#    if options.modify:
#        inbox.mapiobj.DeleteProps([PR_RULES_TABLE]) # XXX
    rule_table = inbox.mapiobj.OpenProperty(PR_RULES_TABLE, IID_IExchangeModifyTable, 0, 0)

    rules = account.get('Rules', [])
    nr_rules += len(rules)

    for rule in rules:
        try:
            if len(rule) < 4:
                nr = 1
                name, conditions, actions = rule
            else:
                nr, name, conditions, actions = rule[:4] # cut off possible comment

            if options.verbose:
                print 'RULE:', nr, name.encode('utf-8')
                for cond in conditions:
                    print 'COND:', cond
                for act in actions:
                    print 'ACTION:', act
                print

            enabled = ST_DISABLED if int(nr) == 0 else ST_ENABLED # priority 0 means inactive rule

            if name == '#Vacation':
                #print 'vacation rule, skipping!\n'
                #continue
                import_vacation_rule = 1
                set_oof = "/usr/bin/zarafa-set-oof -u " + options.users[0] + " -m 1 -t 'Out of Office' -n "
                for cond in conditions:
                    field = cond[0]
                    operator = cond[1]
                    if field == 'Current Date':
                        if operator == 'less than':
                            term = cond[2]
                            if datetime.today() >= datetime.strptime(term, "%d %b %Y") :
                                import_vacation_rule = 0
                                print 'vacation rule: SKIP RULE'
                        elif options.verbose:
                            print 'vacation rule: unsupported operator: "%s"' % operator
                    elif field in  ('Human Generated', 'From') and options.verbose:
                        print 'vacation rule: skipping condition: "%s"' % field
                    elif options.verbose:
                        print 'vacation rule:  unsupported condition: "%s"' % field

                if import_vacation_rule == 1:
                    tf = tempfile.NamedTemporaryFile()
                    for act in actions:
                        if act[0] == 'Reply with':
                            try:
                                tf.write("%s\n" % act[1].encode('utf-8'))
                            except IOError:
                                print "ERROR: can now write to temp file '%s'." % tf.name
                            tf.flush()
                            os.system(set_oof + tf.name)
                        elif act[0] == 'Remember \'From\' in' and options.verbose:
                            print 'vacation rule: skipping: "%s"' % act[0]
                        elif options.verbose:
                            print 'vacation rule: action "%s" not supported' % act[0]
                    tf.close()
                continue

            mapicond = []
            mapiact = []

            for cond in conditions:
                if cond[0] == 'Human Generated':
                    continue

                field, operator, terms = process_condition(cond)

                # subject
                if field == 'Subject':
                    restr = [SContentRestriction(FL_SUBSTRING, PR_SUBJECT, SPropValue(PR_SUBJECT, term)) for term in terms]

                # from address
                elif field in ('From', 'Sender'): # treat Sender as From
                    restr = [SContentRestriction(FL_SUBSTRING, PR_SENDER_SEARCH_KEY, SPropValue(PR_SENDER_SEARCH_KEY, term.upper())) for term in terms]

                # to 
                elif field in ('To', 'Any Recipient', 'Any To or Cc', 'Cc', 'Each To or Cc'): # treat all as To, no substring match.
                    restr = []
                    for term in terms:
                        props, flags = gab.ResolveNames([PR_DISPLAY_NAME_W], (MAPI_UNICODE | EMS_AB_ADDRESS_LOOKUP), [[SPropValue(PR_DISPLAY_NAME_W, unicode(term))]], [MAPI_UNRESOLVED])
                        if flags == [MAPI_RESOLVED]:
                            search_key = 'ZARAFA:'+term.upper()+'\x00'
                            display_name = unicode(props[0][-1].Value)
                        else:
                            search_key = 'SMTP:'+term.upper()+'\x00'
                            display_name = unicode(term) # XXX incorrect but only used as 'comment'
                        restr.append(SSubRestriction(PR_MESSAGE_RECIPIENTS, SCommentRestriction(SPropertyRestriction(RELOP_EQ, PR_SEARCH_KEY, SPropValue(0x00010102, search_key)), [
                            SPropValue(0x60000003, MAPI_TO),
                            SPropValue(0x00010102, search_key),
                            SPropValue(0x0001001F, display_name),
                            SPropValue(PR_DISPLAY_TYPE, DT_MAILUSER),
                        ])))

                # from name
                elif field == "'From' Name": # only supported when name can be resolved against GAB
                    restr = []
                    for term in terms:
                        props, flags = gab.ResolveNames([PR_SMTP_ADDRESS], MAPI_UNICODE, [[SPropValue(PR_DISPLAY_NAME, term)]], [MAPI_UNRESOLVED])
                        if flags == [MAPI_RESOLVED]:
                            email = props[0][-1].Value
                            search_key = 'ZARAFA:'+email.upper()+'\x00'
                            restr.append(SCommentRestriction(SPropertyRestriction(RELOP_EQ, PR_SENDER_SEARCH_KEY, SPropValue(0x00010102, search_key)), [
                                SPropValue(0x60000003, MAPI_TO),
                                SPropValue(0x00010102, search_key),
                                SPropValue(0x0001001F, u'%s <%s>' % (term, email)),
                                SPropValue(PR_DISPLAY_TYPE, DT_MAILUSER),
                            ]))
                        else:
                            raise UnsupportedException("unsupported: 'From' Name condition for unknown user")

                if len(restr) == 1:
                    mapicond.append(restr[0])
                else:
                    mapicond.append(SOrRestriction(restr))

            if actions and actions[-1][0] == 'Stop Processing': # we always stop after conversion
                actions = actions[:-1]

            # no actions: we cannot store this so skip
            if len(actions) == 0:
                pass

            # delete
            elif (len(actions) == 1 and actions[0][0] == 'Discard') or \
                 (len(actions) == 2 and actions[0][0] == actions[1][0] == 'Discard'): # occurs 10+ times
                storeid = user.store.prop(PR_STORE_ENTRYID).value
                targetid = user.store.wastebasket.entryid.decode('hex')
                mapiact.append(ACTION(ACTTYPE.OP_MOVE, 0x00000000, None, None, 0x00000000, actMoveCopy(storeid, targetid)))

            # copy
            elif len(actions) == 1 and actions[0][0] == 'Store in':
                storeid = user.store.prop(PR_STORE_ENTRYID).value
                try:
                    targetid = user.store.folder(actions[0][1]).entryid.decode('hex')
                except zarafa.ZarafaNotFoundException:
                    raise UnsupportedException('unsupported: cannot find folder')
                mapiact.append(ACTION(ACTTYPE.OP_COPY, 0x00000000, None, None, 0x00000000, actMoveCopy(storeid, targetid)))

            # move
            elif (len(actions) == 2 and actions[0][0] == 'Store in' and actions[1][0] == 'Discard') or \
                 (len(actions) == 3 and actions[0][0] == 'Mark' and actions[1][0] == 'Store in' and actions[2][0] == 'Discard') or \
                 (len(actions) == 3 and actions[0][0] == 'Store in' and actions[1][0] == 'Mark' and actions[2][0] == 'Discard'):
                storeid = user.store.prop(PR_STORE_ENTRYID).value
                store_action = [act for act in actions if act[0] == 'Store in'][0]
                try:
                    targetid = user.store.folder(store_action[1]).entryid.decode('hex')
                except zarafa.ZarafaNotFoundException:
                    raise UnsupportedException('unsupported: cannot find folder')
                mapiact.append(ACTION(ACTTYPE.OP_MOVE, 0x00000000, None, None, 0x00000000, actMoveCopy(storeid, targetid)))

            # forward
            elif (len(actions) == 1 and actions[0][0] == 'Forward to') or \
                 (len(actions) == 2 and actions[0][0] == 'Forward to' and actions[1][0] == 'Tag Subject'):
                email = unicode(actions[0][1])
                mapiact.append(action_forward(ab, 0, email))
            elif len(actions) == 2 and actions[0][0] == 'Forward to' and actions[1][0] == 'Discard':
                email = unicode(actions[0][1])
                mapiact.append(action_forward(ab, 0, email))
                mapiact.append(action_delete(user.store))

            # redirect, mirror
            elif len(actions) == 1 and actions[0][0] in ('Redirect to', 'Mirror to'):
                email = unicode(actions[0][1])
                mapiact.append(action_forward(ab, FWD_PRESERVE_SENDER | FWD_DO_NOT_MUNGE_MSG, email))
            elif len(actions) == 2 and actions[0][0] in ('Redirect to', 'Mirror to') and actions[1][0] == 'Discard':
                email = unicode(actions[0][1])
                mapiact.append(action_forward(ab, FWD_PRESERVE_SENDER | FWD_DO_NOT_MUNGE_MSG, email))
                mapiact.append(action_delete(user.store))

            else:
                raise UnsupportedException('unsupported action sequence: %s' % [action[0] for action in actions])

            if mapiact and options.modify:
                rule_table.ModifyTable(0, [ ROWENTRY(ROW_ADD,
                                                 [   SPropValue(PR_RULE_LEVEL, 0),
                                                     SPropValue(PR_RULE_NAME, name.encode('ascii', 'replace')), # XXX
                                                     SPropValue(PR_RULE_PROVIDER, "RuleOrganizer"),
                                                     SPropValue(PR_RULE_STATE, enabled | ST_EXIT_LEVEL), # st_exit_level: stop processing after..
                                                     SPropValue(PR_RULE_SEQUENCE, 1),
                                                     SPropValue(PR_RULE_CONDITION, mapicond[0] if len(mapicond) == 1 else SAndRestriction(mapicond)),
                                                     SPropValue(PR_RULE_ACTIONS, ACTIONS(EDK_RULES_VERSION, mapiact))
                                                 ]
                                                 ) ] )
        except Exception, e:
            print 'ERROR: could not process rule. reason:'
            if isinstance(e, UnsupportedException):
                print e.message
                nr_unsupported += 1
            else:
                print traceback.format_exc(e)
                nr_error += 1
            print

#    table = zarafa.Table(server, rule_table.GetTable(0), PR_RULES_TABLE)
#    print table.text()

def main():
    global nr_error
    options, args = zarafa.parser('cskpUPmvu').parse_args()
    server = zarafa.Server()
    if len(args) == 1 and os.path.isdir(args[0]):
        data = []
        for filename in sorted(glob.glob(args[0]+'/*/account.settings')):
            print 'ACCOUNT:', filename
            data.append(('{\nRealName = "%s";\n' % filename.split(os.path.sep)[-2])+file(filename).read()+'\n}')
    elif args:
        data = [file(arg).read() for arg in args]
    else:
        data = [TEST_ACCOUNT]

    for d in data:
        try:
            account = cgon.loads(d.strip())
            process_account(account, server, options)
        except Exception, e:
            print traceback.format_exc(e)
            nr_error += 1

    print 'rules:', nr_rules
    print 'unsupported:', nr_unsupported
    print 'errors:', nr_error
    if nr_error:
        sys.exit(1)

if __name__ == '__main__':
    main()
