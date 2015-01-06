#!/bin/bash

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

### CommunigatePro Import scripts
### Version 1.11sj

# Description:
# TODO
# ...
# I tried to call the do_curl_* functions in background with &, but that
# causes too many connections to the webserver which in turn causes the
# curl commands to fail. So I decided to make serialize all function calls.

CONFIG_FILE='/etc/zarafa/cgp-migrate.conf'
FAILED_ITEMS_FOLDER='cgp-migrate.failed.items'
STATUS='0'
CHECK_ITEMS='0'
CHECK_COUNT='1'
SEND_INFO_MAIL='1'
FAIL_ON_RULES='0'
DEFAULT_CALENDAR_FOLDERS='Agenda|Kalender|Calendario|Calendar'
DEFAULT_TASK_FOLDERS='Tâches|Aufgaben|Tareas|Tasks'
DEFAULT_CONTACT_FOLDERS='Attività|Contacts|Kontakte|Contactos|Contatti'
MY_LANG='de_DE.UTF-8'

# keep track of mail folders
declare -A used_folders
declare -A created_folders
declare -A zarafa_folders

# have ipf types in
declare -A ipf_types;
ipf_types['CONTACT']='IPF.Contact'
ipf_types['TASK']='IPF.Task'
ipf_types['CALENDAR']='IPF.Appointment'
ipf_types['NOTE']='IPF.StickyNote'

# store failed calendar items in this file:
failed_cal_items='failed_calendar_items'

##### Functions start ######
function usage {
   echo "Usage: ${0##*/} -u <primary source user> -U <destination user>"
   echo "       [-s <secondary source user> [-s ...]]"
   echo "       [-p <source user pw>] [-P <destination user pw>]"
   echo "       [-h <source imap host>] [-H <destination imap host>]"
   echo "       [-m <info mail rcpt>]"
   echo "       [-C] [-T] [-M] [-R]"
   echo
   echo " Use -C to check a successfull upload after each item"
   echo " Use -T do disable checking the folder count"
   echo "        (compare amount of to import and imported items)"
   echo " Use -M to prevent script from sending mails"
   echo " Use -R to fail on rule import errors"
   #"echo "      [-D <destination domain>]"
   exit 1
}

function log_msg {
   local LOG_TYPE=$1
   local MSG=$2
   if [[ ${#LOG_TYPE} -lt 12 ]] ; then
      for f in $(seq ${#LOG_TYPE} 10); do
         LOG_TYPE=" $LOG_TYPE"
      done
   fi
   date "+[${LOG_TYPE}] %H:%M:%S === ${MSG} ==="
}

function get_status {
   local RETVAL="$?"
   if [[ "$RETVAL" != '0' ]]; then
      STATUS=1
      echo "error" >> ${RAMDISK_LOCATION}/${DEST_USER}.errors
      log_msg 'MIGRATION' "ERROR: $1 faild with $RETVAL"
   fi
   return $RETVAL
}

function clean_ramdisk {
   if mount | grep -q "${RAMDISK_LOCATION}" ; then
      umount ${RAMDISK_LOCATION} 2>&1 >/dev/null
   fi
   if rm -rf ${RAMDISK_LOCATION} ; then
     log_msg 'PREPARE' "remove working directory: ${RAMDISK_LOCATION}"
   else
     log_msg 'PREPARE' "ERROR: failed to remove working directory: ${RAMDISK_LOCATION}"
   fi
}

function rebuild_calendar {
   # attribute1: required: calendar file
   if [ -z "$1" ]; then
      log_msg 'FUNCTION' "ERROR: function $FUNCNAME needs argument"
   fi
   local ics_file="$1"
   sed -i '/\(^\(BEGIN\|END\):VCALENDAR\|^VERSION:2.0\|^METHOD:PUBLISH\)/d' "$ics_file"
   sed -i '1s/^/BEGIN:VCALENDAR\nVERSION:2.0\nMETHOD:PUBLISH\n/' "$ics_file"
   echo -e "END:VCALENDAR" >> "$ics_file"
}

function do_curl_CALENDAR {
   ## use MBOXNAME_TASK instead of MBOXNAME
   # attribute1: required: source ics file (e.g. import-${MBOXNAME}.cal.ics)
   local source_ics="$1"
   # attribute2: optional: true or no_priv
   local import_private=${2:-'true'}
   local upload_url="http://${ICAL_IP}:${ICAL_PORT}/ical/${DEST_USER}/${MBOXNAME_CALENDAR}/"
   local item_count="$(grep -c BEGIN:VEVENT $source_ics)"
   local pre_item_count=0
   local empty_calendar='BEGIN:VCALENDAR\nVERSION:2.0\nMETHOD:PUBLISH\nEND:VCALENDAR'

   if [[ "$CHECK_ITEMS" -eq 1 ]]; then
      # empty folder before uploading
      [[ $DEBUG -eq 1 ]] && echo curl --retry 3 -sS -u "$ICAL_USER" -T - $upload_url
      echo -e "$empty_calendar" | curl --retry 3 -sS -u "$ICAL_USER" -T - $upload_url
      get_status curl
      pre_item_count="$(curl --retry 3 -sS -u "$ICAL_USER" $upload_url | grep -c BEGIN:VEVENT)"
   fi
   # import once with no private flags for comparison and make the summary uniq
   # and keep a copy of the original for comparision
   cat "$source_ics" | perl -ne 's/^SUMMARY:/"SUMMARY:" . ++$cnt ." "/ge; print $_;' > "${source_ics}.uniq"
   cp "${source_ics}.uniq" "${source_ics}.noprivate.uniq"
   sed -i '/^CLASS:/d' "${source_ics}.noprivate.uniq"

   log_msg 'CALENDAR' "Importing calendar with non-private settings"
   [[ $DEBUG -eq 1 ]] && echo curl --retry 3 -sS -u "$ICAL_USER" -T "${source_ics}.noprivate.uniq" $upload_url
   curl --retry 3 -sS -u "$ICAL_USER" -T "${source_ics}.noprivate.uniq" $upload_url
   get_status curl
   rm -f "${source_ics}.noprivate.uniq"

   # do comparison check here
   grep -i ^SUMMARY "${source_ics}.uniq" | sed -e 's#\\"##g' -e 's#"##g' -e 's# $##g' | \
      sed -e 's#^\(SUMMARY:[0-9]*\).*#\1#g' | sort > "${source_ics}.src"
   curl --retry 3 -sS -u "$ICAL_USER" $upload_url | grep -i ^SUMMARY | \
      sed -e 's#\\"##g' -e 's#"##g' -e 's# $##g' | sed -e 's#^\(SUMMARY:[0-9]*\).*#\1#g' | sort > "${source_ics}.dst"
   dos2unix -q "${source_ics}.dst"
   [[ $DEBUG -eq 1 ]] && diff -p "${source_ics}.src" "${source_ics}.dst"
   diff -p "${source_ics}.src" "${source_ics}.dst" | grep '^- SUMMARY' | \
      sed -e '/^- SUMMARY:$/d' -e 's#- ##g' | uniq > $failed_cal_items
   while read line; do
      if [ -n "$line" ]; then
         grep "$line" "${source_ics}.uniq" -B40 -A40 | \
            sed '/^BEGIN:VEVENT/,/^END:VEVENT/!d' >> \
            "${RAMDISK_LOCATION}/${FAILED_ITEMS_FOLDER}"/calendar
      fi
   done < $failed_cal_items
   cp $failed_cal_items "${RAMDISK_LOCATION}/${FAILED_ITEMS_FOLDER}/"
   if [ -f "${RAMDISK_LOCATION}/${FAILED_ITEMS_FOLDER}"/calendar ]; then
      pushd "${RAMDISK_LOCATION}/${FAILED_ITEMS_FOLDER}" >/dev/null
      #csplit -q calendar "/^BEGIN:\(VCALENDAR\|VCARD\|VGROUP\)/" {*}
      csplit -q calendar "/^BEGIN:VEVENT/" {*}
      rm -f xx00
      for i in xx*; do
         if [ -f $i ]; then
            if grep -q -f $failed_cal_items $i ; then
               mv $i "${source_ics%.cal.ics}-${i}.ics"
            else
               rm -f $i
            fi
         else
            log_msg 'MIGRATION' "WARN: failed to extract VCALENDAR from ${source_ics}"
         fi
      done
      rm -f calendar
      popd >/dev/null
   fi
   rm -f "${RAMDISK_LOCATION}/${FAILED_ITEMS_FOLDER}/${failed_cal_items}"

   ## check status if running in CHECK_ITEMS mode and import private is not requested
   if [[ "$CHECK_ITEMS" -eq 1 ]] && [[ "$import_private" != 'true' ]]; then
      local failed_counter="$(cat $failed_cal_items | wc -l)"
      if [ "$failed_counter" -gt 0 ]; then
         log_msg 'MIGRATION' "CHECKING: failed items: ${MBOXNAME_CALENDAR}: $failed_counter"
         echo FAIL
      else
         echo OK
      fi
   fi

   if [[ "$import_private" == 'true' ]]; then
      # now import all with appropriate private flags
      echo -e "$empty_calendar" | curl --retry 3 -sS -u "$ICAL_USER" -T - $upload_url
      log_msg 'CALENDAR' "Importing calendar with all private settings"
      [[ $DEBUG -eq 1 ]] && echo curl --retry 3 -sS -u "$ICAL_USER" -T "$source_ics" $upload_url
      curl --retry 3 -sS -u "$ICAL_USER" -T "$source_ics" $upload_url
      get_status curl

      if [[ "$CHECK_ITEMS" -eq 1 ]]; then
         local item="$(curl --retry 3 -sS -u "$ICAL_USER" ${upload_url})"
         get_status curl
         local post_item_count="$(echo "$item" | grep -c BEGIN:VEVENT)"
         log_msg 'CALENDAR' "Before upload: ${pre_item_count}; Items uploaded: ${item_count}; After upload: ${post_item_count}"
         if [[ $(( $item_count + $pre_item_count )) -ne "$post_item_count" ]]; then
            # this works only with single events
            # cat "$source_ics" >> "${RAMDISK_LOCATION}/${FAILED_ITEMS_FOLDER}/${source_ics##*/}"
            log_msg 'MIGRATION' "ERROR: failed to upload ics. ${DEST_USER}: ${source_ics##*/}"
         fi
      fi
   fi
}

function do_curl_CONTACT {
   ## use MBOXNAME_CONTACT instead of MBOXNAME  
   # attribute1: required: source vcf file (e.g. import-${MBOXNAME_CONTACT}-${VCFNAME}.${SUFFIX})
   local source_vcf="$1"
   local upload_url="http://${VCARD_IP}/zarafa-sabre/addressbooks/${DEST_USER}/${MBOXNAME_CONTACT}/"
   local upload_user="${DEST_USER}:notused"

   [[ $DEBUG -eq 1 ]] && echo curl --retry 3 -sS -u "$upload_user" -T "$source_vcf" $upload_url
   curl --retry 3 -sS -u "$upload_user" -T "$source_vcf" $upload_url
   get_status curl
}

function do_curl_TASK {
   ## use MBOXNAME_TASK instead of MBOXNAME  
    # attribute1: required: source task file (e.g. import-${MBOXNAME}-${TASKNAME}.${SUFFIX}"
   local source_task="$1"
   local upload_url="http://${ICAL_IP}:${ICAL_PORT}/caldav/${DEST_USER}/${MBOXNAME_TASK}/"

   [[ $DEBUG -eq 1 ]] && echo curl --retry 3 -sS -u "$ICAL_USER" -T "$source_task" $upload_url
   curl --retry 3 -sS -u "$ICAL_USER" -T "$source_task" $upload_url
   get_status curl
}

function do_imapsync {
   local account="$1"
   local prefix=''
   # if primary account is not processed then set an other prefix
   if [ "$account" != "${SOURCE_USER}" ]; then
      local prefix="${account%@*}/"
   fi
   # set imapsync command
   # defaults: --nosyncacls --syncinternaldates --skipsize
   # provided by NAMESPACE: --sep2 '/' --prefix2 ""
   imapsync --noreleasecheck --addheader --buffersize 8192000 --nofoldersizes --fast --noauthmd5 \
      --useheader ALL --reconnectretry1 10 --reconnectretry2 10 \
      --host1 "$SOURCE_IMAP_IP" --user1 "$account"   --password1 "$SOURCE_IMAP_PASSWORD" --ssl1 \
      --host2 "$DEST_IMAP_IP"   --user2 "$DEST_USER" --password2 "$DEST_IMAP_PASSWORD" \
      --authmech2 plain --prefix2 "$prefix" --delete2 \
      --regextrans2 's/^Sent$/Gesendete Objekte/' --regextrans2 's/^Drafts$/Entw&APw-rfe/' \
      --regextrans2 's/^Trash$/Gel&APY-schte Objekte/' --regextrans2 's/^Junk-E-Mail$/Junk E-Mail/'
   #  2> /dev/null
   get_status imapsync
}

function do_import_rules {
   # attribute1: required: path to account.settings file
   local account_settings="$1"
   if ! [ -r "$account_settings" ]; then
      log_msg 'RULES' "error: can not read $account_settings"
      return 1
   else
      python ${TOOL_LOCATION}/convert_rules.py ${DEBUG:+-v} \
         -m -u ${DEST_USER} $account_settings ;
   fi
}

function update_zarafa_folder_list {
   ## Assuming: 
   ##   * each calendar, tasks and contacts folder name is unique
   ##   * each account is empty before import starts
   ##     (calendar will be overwriten anyway)
   ##
   ## get folder list with element count from zarafa.
   ## list-folder-size.py gives the following output:
   ## --IPM_SUBTREE|0
   ## ----Aufgaben|0
   ## ------Subtasks|1
   ## ----Mailbox
   ## ----Kalender|2
   ## ------Subkalender2|1
   ## ...
   ## Try to find Aufgaben, Kalender and Kontakte and from there on process
   ## each folder if its name starts with '------'
   local next=0
   local count_pos=0
   local folder_pos=0
   local folder_count=0
   local folder_name=''

   while read line ; do
      if [[ "$line" =~ ^----$CALENDAR_FOLDER ]] ||
         [[ "$line" =~ ^----$CONTACTS_FOLDER ]] ||
         [[ "$line" =~ ^----$TASKS_FOLDER ]] ||
         ( [ "$next" -eq 1 ] && [[ "$line" =~ ^------ ]] ); then
         next=1
         # number of bars == count position
         count_pos="$(echo $line | sed -e 's/[^|]//g' | wc -c)"
         folder_pos=$(( $count_pos - 1 ))
         folder_count="$(echo $line | cut -d'|' -f $count_pos)"
         folder_name="$(echo $line | cut -d'|' -f 1-${folder_pos} | sed -e 's/^-----*//')"
         if [ "$folder_count" -ne 0 ]; then
            if [ -n "${zarafa_folders["$folder_name"]}" ]; then
               zarafa_folders["$folder_name"]=$(($folder_count - ${zarafa_folders["$folder_name"]}))
            else
               zarafa_folders["$folder_name"]=$folder_count
            fi
         fi
      elif [ "$next" -eq 1 ] && [[ "$line" =~ '^----' ]] ; then
        next=0
      fi
   done <<< "$(LANG="$MY_LANG" ${TOOL_LOCATION}/list-folder-size.py ${DEST_USER} | head -n -1)"
}
##### Functions end ######

##### MAIN START ######
# check for needed perl modules
if ! perl -MEncode -MEncode::IMAPUTF7 -e 'print $Encode::IMAPUTF7::VERSION' &> /dev/null ; then
   log_msg 'STARTUP' 'ERROR: CAN NOT LOAD Perl Library Encode::IMAPUTF7'
   exit 1
fi

# check for needed binaries
for exe in '/usr/bin/uuidgen' '/usr/bin/imapsync' '/usr/bin/dos2unix' ; do
   if ! [ -x "$exe" ]; then
      log_msg 'STARTUP' "ERROR: can not find/execute ${exe}"
      exit 1
   fi
done

# source config file
if [ -r "$CONFIG_FILE" ]; then
   source "$CONFIG_FILE"
else
   log_msg 'STARTUP' "ERROR: can not source $CONFIG_FILE !"
   exit 1
fi

# try to find an other config file in cwd
if [ -r './cgp-migrate.conf' ]; then
   source "./cgp-migrate.conf"
fi

# check config file options:
if [ -z "$INFO_MAIL_SENDER" ] || [ -z "$INFO_MAIL_SUBJECT" ] || \
   [ -z "$INFO_MAIL_BODY" ];then
   log_msg 'STARTUP' 'ERROR one or more INFO_MAIL_* variables are empty'
   exit 1
fi

# overwrite config file options by command line options
while getopts ":u:U:m:p:P:s:h:H:CMT" opt; do
   case $opt in
      u) SOURCE_USER="$OPTARG"
         ;;
      s) SOURCE_SEC_USER="$SOURCE_SEC_USER $OPTARG"
         ;;
      U) DEST_USER="$OPTARG"
         ;;
      p) SOURCE_IMAP_PASSWORD="$OPTARG"
         ;;
      P) DEST_IMAP_PASSWORD="$OPTARG"
         ;;
      h) SOURCE_IMAP_IP="$OPTARG"
         ;;
      H) DEST_IMAP_IP="$OPTARG"
         ;;
      m) INFO_MAIL_RCPT="$OPTARG"
         ;;
      M) SEND_INFO_MAIL='0'
         ;;
      C) CHECK_ITEMS=1
         ;;
      T) CHECK_COUNT=0
         ;;
      R) FAIL_ON_RULES=1
         ;;
      \?) usage
         ;;
      :) usage
         ;;
   esac
done

# check options for validity:
if [ -z "$SOURCE_USER" ] || [ -z "$DEST_USER" ]; then
   log_msg 'STARTUP' 'ERROR: No source or destination user defined'
   usage
fi
if [ -z "$SOURCE_IMAP_IP" ] || [ -z "$DEST_IMAP_IP" ]; then
   log_msg 'STARTUP' 'ERROR: No source or destination IMAP Host/IP defined'
   usage
fi
if [ -z "$SOURCE_IMAP_PASSWORD" ]; then
   log_msg 'STARTUP' 'ERROR: No source IMAP password defined'
   usage
fi

# set variables which depend on the config file
ICAL_USER="${ZARAFA_ADMIN_USER}:${ZARAFA_ADMIN_PASSWORD}"
RAMDISK_LOCATION="${RAMDISK_ROOT}/${DEST_USER}"

# check if source domain folder exists:
if ! [ -d "${DATA_LOCATION}/${SOURCE_USER##*@}" ]; then
   log_msg 'STARTUP' "ERROR: directory ${DATA_LOCATION}/${SOURCE_USER##*@} does not exists"
   exit 1
fi

if [[ $DEBUG -eq 1 ]]; then
   exec 2> "/tmp/trace_${DEST_USER}"
   set -x
fi

if [ "$CLEAN_RAMDISK_BEFORE_RUN" = 1 ] ; then
   clean_ramdisk
fi
mkdir -p "${RAMDISK_LOCATION}" 2>&1 >/dev/null
log_msg 'PREPARE' "created working dir: ${RAMDISK_LOCATION}"
if [ "$CREATE_RAMDISK" = 1 ]; then
   mount -t tmpfs -o size=${RAMDISK_SIZE} none "${RAMDISK_LOCATION}"
fi

## create a file which will store async. error msgs
touch "${RAMDISK_LOCATION}/${DEST_USER}.errors"

# create a folder where failed items will be stored
mkdir -p "${RAMDISK_LOCATION}/${FAILED_ITEMS_FOLDER}"
get_status mkdir

pushd "${DATA_LOCATION}/${SOURCE_USER##*@}" 2>&1 >/dev/null
if [ -d "${SOURCE_USER%%@*}.macnt" ]; then
   # get CGP's default calendar, task and contacts folder
   tmp_cal_path=$(grep '#Viewer' ${SOURCE_USER%%@*}.macnt/account.info | \
      cut -d{ -f2 | tr ';' '\n' | grep CalendarBox | cut -d= -f2 | tr -d '"')
   CALENDARBOX="$(echo ${tmp_cal_path##*/} | sed -e 's# #_#g')"
   CALENDARBOX_PATH="$(echo ${tmp_cal_path} | \
      sed -e 's#[^/]*$##' -e 's# #_#g')"
   tmp_task_path=$(grep '#Viewer' ${SOURCE_USER%%@*}.macnt/account.info | \
      cut -d{ -f2 | tr ';' '\n' | grep TasksBox | cut -d= -f2 | tr -d '"')
   TASKSBOX="$(echo ${tmp_task_path##*/} | sed -e 's# #_#g')"
   TASKSBOX_PATH="$(echo ${tmp_task_path} | \
      sed -e 's#[^/]*$##' -e 's# #_#g')"
   tmp_contact_path=$(grep '#Viewer' ${SOURCE_USER%%@*}.macnt/account.info | \
      cut -d{ -f2 | tr ';' '\n' | grep ContactsBox | cut -d= -f2 | tr -d '"')
   CONTACTSBOX="$(echo ${tmp_contact_path##*/} | sed -e 's# #_#g')"
   CONTACTSBOX_PATH="$(echo ${tmp_contact_path} | \
      sed -e 's#[^/]*$##' -e 's# #_#g')"
else
   log_msg 'MIGRATION' "ERROR: source user directory doesn't exist: ${SOURCE_USER%%@*}.macnt"
   STATUS=1
fi
[ -z "$CALENDARBOX" ] && CALENDARBOX='Calendar'
[ -z "$TASKSBOX" ] && TASKSBOX='Tasks'
[ -z "$CONTACTSBOX" ] && CONTACTSBOX='Contacts'


# get Zarafa user's default calendar, tasks and contacts folder
${TOOL_LOCATION}/get-folder-name.py -u ${DEST_USER} > ${RAMDISK_LOCATION}/${DEST_USER}.destfolders
if [[ `cat ${RAMDISK_LOCATION}/${DEST_USER}.destfolders | wc -l` -gt "0" ]]; then
   CALENDAR_FOLDER="`grep CALENDAR ${RAMDISK_LOCATION}/${DEST_USER}.destfolders | awk '{ print $2 }'`"
   TASKS_FOLDER="`grep TASKS ${RAMDISK_LOCATION}/${DEST_USER}.destfolders | awk '{ print $2 }'`"
   CONTACTS_FOLDER="`grep CONTACTS ${RAMDISK_LOCATION}/${DEST_USER}.destfolders | awk '{ print $2 }'`"
else
   log_msg 'MIGRATION' "ERROR: DEFAULT FOLDERS COULD NOT BE FOUND IN DESTINATION - EXIT ($DEST_USER)"
   exit 1
fi
# mark these folders as created
created_folders["CALENDAR:${CALENDAR_FOLDER}"]='1'
created_folders["TASK:${TASKS_FOLDER}"]='1'
created_folders["CONTACT:${CONTACTS_FOLDER}"]='1'

log_msg MIGRATION "PROCESSING user ${SOURCE_USER%%@*} ${SOURCE_SEC_USER%%@*} -> ${DEST_USER}"
# log the standard folder
log_msg 'DEFAULTS' "CALENDARBOX: ${CALENDARBOX_PATH}${CALENDARBOX} -> ${CALENDAR_FOLDER}"
log_msg 'DEFAULTS' "TASKSBOX:    ${TASKBOX_PATH}${TASKSBOX} -> ${TASKS_FOLDER}"
log_msg 'DEFAULTS' "CONTACTSBOX: ${CONTACTSBOX_PATH}${CONTACTSBOX} -> ${CONTACTS_FOLDER}"


## iterate over all source user accounts
for source_account in ${SOURCE_USER} ${SOURCE_SEC_USER} ; do
   pushd "${DATA_LOCATION}/${source_account##*@}" 2>&1 >/dev/null
   # Get a list of all mbox files
   MBOXFILE_LIST="$(find -L ${source_account%%@*}.macnt -iname "*.mbox" | sed -e '/Trash/d')"
   log_msg 'MIGRATION' "START PROCESSING user ${source_account%%@*} -> ${DEST_USER}"

   while read -r MBOXFILE; do
      if [ -z "$MBOXFILE" ]; then
         continue
      fi
      # keep track of UIDs in calendars
      unset uid_list
      declare -A uid_list

      MBOXNAME="$(echo ${MBOXFILE} | sed -e 's#.mbox##' -e 's#.*\/##g' -e 's# #_#g' -e 's#\[##g' -e 's#\]##g' \
          | perl -MEncode -MEncode::IMAPUTF7 -e "print encode('UTF8', decode('IMAP-UTF-7', <>));" )"

      log_msg 'MBOXFILE' "START ${MBOXFILE}"
      log_msg 'MBOXFILE' "MBOXNAME: ${MBOXNAME}"
      # get folder level
      LEVEL=$(echo ${MBOXFILE} | tr '/' '\n' | wc -l)
      FPATH=$(echo ${MBOXFILE//.folder} | \
                 sed -e 's#/\+#/#' -e 's#^[^/]*/##' -e 's#[^/]*$##' -e 's# #_#g')
      # generate a random foldername extension
      URAND="_$(cat /dev/urandom | tr -cd [:alnum:] | head -c 4)"

      # remove CGP standard folder from folder path, because zarafa folders are
      # per default under the default folder
      for f in ${DEFAULT_CALENDAR_FOLDERS//|/ } ${DEFAULT_TASK_FOLDERS//|/ } \
               ${DEFAULT_CONTACT_FOLDERS//|/ } ; do
         FPATH=${FPATH#${f}/}
      done

      # if primary account is not processed then add folder (== account name) to path
      if [ "$source_account" != "${SOURCE_USER}" ]; then
         FPATH="${source_account%%@*}/${FPATH}"
         MBOXNAME="${source_account%%@*}_${MBOXNAME}"
      fi

      # Is the actual mailbox our default calendar folder?
      if [[ "$FPATH" == "${CALENDARBOX_PATH}" ]] && [[ "${MBOXNAME}" == "${CALENDARBOX}" ]] ; then
         MBOXNAME="$CALENDAR_FOLDER"
         FPATH=''
         LEVEL=2
         ## import as mbox
         #cp "${MBOXFILE}" "${RAMDISK_LOCATION}/${MBOXFILE##*/}_with_attachment"
         #${TOOL_LOCATION}/import-mbox.py "${DEST_USER}" 'IPF.Appointment' "${RAMDISK_LOCATION}/${MBOXFILE##*/}_with_attachment"
         #rm -f "${RAMDISK_LOCATION}/${MBOXFILE##*/}_with_attachment"
      # zarafa thinks 'calendar' == 'kalender', so rewrite it to an other name
      # this includes $CALENDAR_FOLDER
      elif [[ "${MBOXNAME}" =~ ^${DEFAULT_CALENDAR_FOLDERS//|/$|^}$ ]] ; then
         MBOXNAME="${MBOXNAME}${URAND}"
      fi

      # Is the actual mailbox our default tasks folder?
      if [[ "$FPATH" == "${TASKSBOX_PATH}" ]] && [[ "${MBOXNAME}" == "${TASKSBOX}" ]] ; then
         MBOXNAME="$TASKS_FOLDER"
         FPATH=''
         LEVEL=2
         ## import as mbox
         #cp "${MBOXFILE}" "${RAMDISK_LOCATION}/${MBOXFILE##*/}_with_attachment"
         #${TOOL_LOCATION}/import-mbox.py "${DEST_USER}" 'IPF.Task' "${RAMDISK_LOCATION}/${MBOXFILE##*/}_with_attachment"
         #rm -f "${RAMDISK_LOCATION}/${MBOXFILE##*/}_with_attachment"
      # zarafa thinks 'Tasks' == 'Aufgaben', so rewrite it to an other name
      # this includes $TASKS_FOLDER
      elif [[ "${MBOXNAME}" =~ ^${DEFAULT_TASK_FOLDERS//|/$|^}$ ]] ; then
         MBOXNAME="${MBOXNAME}${URAND}"
      fi

      # Is the actual mailbox our default contacts folder?
      if [[ "$FPATH" == "${CONTACTSBOX_PATH}"  ]] && [[ "${MBOXNAME}" == "${CONTACTSBOX}" ]] ; then
         MBOXNAME=$CONTACTS_FOLDER
         FPATH=''
         LEVEL=2
      # zarafa thinks 'Contacts' == 'Kontakte', so rewrite it to an other name
      # this includes $CONTACTS_FOLDER
      elif [[ "${MBOXNAME}" =~ ^${DEFAULT_CONTACT_FOLDERS//|/$|^}$ ]] ; then
         MBOXNAME="${MBOXNAME}${URAND}"
      fi

      # if mbox exists, rename it; don't use $URAND
      if [ -n "${used_folders["${MBOXNAME}"]}" ]; then
         MBOXNAME="${MBOXNAME}_$(cat /dev/urandom | tr -cd [:alnum:] | head -c 4)"
      fi
      # mark mbox as used
      if [ -n "${used_folders["${MBOXNAME}"]}" ]; then
         log_msg MIGRATION "FAILED: FOLDER ${MBOXNAME} EXISTS (${DEST_USER})"
         exit 1
      else
         used_folders["${MBOXNAME}"]='0'
      fi

      # log the infos we obtained so far
      log_msg 'MBOXFILE' "MBOXNAME: ${MBOXNAME} LEVEL: ${LEVEL} FPATH: ${FPATH}"

      mkdir -p "${RAMDISK_LOCATION}/${MBOXFILE}"
      cp "${MBOXFILE}" "${RAMDISK_LOCATION}/${MBOXFILE}/"
      pushd "${RAMDISK_LOCATION}/${MBOXFILE}" 2>&1 >/dev/null
      csplit -q -- *.mbox "/^BEGIN:\(VCALENDAR\|VCARD\|VGROUP\)/" {*} 2>&1 >/dev/null
      get_status csplit
      MBOXNAME_DEFAULT="$MBOXNAME"
      FPATH_DEFAULT="$FPATH"
      FIRSTTYPE=''
      for STRIPFILE in xx*; do
         MBOXNAME="$MBOXNAME_DEFAULT"
         FPATH="$FPATH_DEFAULT"
         if [ "$(grep -a ^BEGIN:VCALENDAR ${STRIPFILE} | wc -l)" -gt '0' ] && \
            [ "$(grep -a ^METHOD:PUBLISH ${STRIPFILE} | wc -l)" -gt '0' ] && \
            [ "$(grep -a ^BEGIN:VTODO ${STRIPFILE} | wc -l)" -lt '1' ] && \
            [ "${MBOXNAME}" != "INBOX" ]; then
            TYPE='CALENDAR'
            TAG='VCALENDAR'
            SUFFIX="cal.ics"
            [[ ${DO_CALENDAR} -eq 0 ]] && DO_SKIP=1
         elif [ "$(grep -a ^BEGIN:VCALENDAR ${STRIPFILE} | wc -l)" -gt '0' ] && \
              [ "$(grep -a ^METHOD:PUBLISH ${STRIPFILE} | wc -l)" -gt '0' ] && \
              [ "$(grep -a ^BEGIN:VTODO ${STRIPFILE} | wc -l)" -gt '0' ]; then
            TYPE='TASK'
            TAG='VCALENDAR'
            SUFFIX='task.ics'
            [[ ${DO_TASKS} -eq 0 ]] && DO_SKIP=1
         elif [ "$(grep -a '^BEGIN:VCARD' ${STRIPFILE} | wc -l)" -gt '0' ] ; then
            TYPE='CONTACT'
            TAG='VCARD'
            SUFFIX='vcf'
            [[ ${DO_CONTACTS} -eq 0 ]] && DO_SKIP=1
         elif [ "$(grep -a '^BEGIN:VGROUP' ${STRIPFILE} | wc -l)" -gt '0' ] ; then
            TYPE='GROUP'
            TAG='VGROUP'
            SUFFIX='vgf'
            [[ ${DO_CONTACTS} -eq 0 ]] && DO_SKIP=1
         else
            TYPE="FOLDER"
         fi
         if [[ ( "${TYPE}" = 'TASK' || \
                 "${TYPE}" = 'CALENDAR' || \
                 "${TYPE}" = 'CONTACT' || \
                 "${TYPE}" = 'GROUP' ) && \
                  ${DO_SKIP} -eq 0 && "${MBOXNAME}" != 'INBOX' ]]; then
            grep -a -B 10000000 "^END:${TAG}" ${STRIPFILE} | sed -e '/^PRODID/d' \
                  >> ${STRIPFILE}.${SUFFIX}
            rm -f ${STRIPFILE}
            log_msg "${TYPE}" "START ${MBOXFILE} ${STRIPFILE}"
            if [ -z "$FIRSTTYPE" ]; then
               FIRSTTYPE="$TYPE"
            fi
            if [[ -s ${STRIPFILE}.${SUFFIX} ]]; then
               if [[ ${TYPE} = "CALENDAR" ]]; then
                  import_status_cal='OK'  # set default
                  # change mboxname if mailbox has changed its type
                  if [[ "$FIRSTTYPE" != "$TYPE" ]] ; then
                     log_msg "${TYPE}" "RENAME FOLDER ${MBOXNAME} -> ${MBOXNAME}_C"
                     MBOXNAME="${MBOXNAME}_C"
                     FPATH="${FPATH//\//_C/}"
                  fi
                  ## create folder
                  if [ -z "${created_folders["${TYPE}:${FPATH}${MBOXNAME}"]}" ]; then
                     ${TOOL_LOCATION}/create-folder.py -u ${DEST_USER} -f "${FPATH}${MBOXNAME}" -t ${ipf_types[$TYPE]}
                     created_folders["${TYPE}:${FPATH}${MBOXNAME}"]='1'
                  fi
                  # remember mboxname for counting items
                  MBOXNAME_CALENDAR="$MBOXNAME"
                  # use tempfile for preprocessing and rewriting of uids
                  UID_TEST_FILE="import-uid-test.${SUFFIX}"

                  # preprocess calendar
                  #perl -MMIME::QuotedPrint -ne 'if ($_ =~ /=$/) {print decode_qp($_); } else { print $_ ; }' ${STRIPFILE}.${SUFFIX} | \
                  perl -p00e 's/\r?\n //g' ${STRIPFILE}.${SUFFIX} | \
                     sed -e 's#DT\(.*\);TZID=.*:\(.*\)#DT\1:\2Z#g' | \
                     grep -vf ${TOOL_LOCATION}/cgp-attribute-strip.txt > "${UID_TEST_FILE}"

                  # keep track of UIDs
                  cal_uid="$(grep '^UID:' "${UID_TEST_FILE}" | cut -d':' -f 2 )"
                  if [ "$(echo "$cal_uid" | wc -l)" -gt 1 ]; then
                     log_msg "$TYPE" "WARN: found more that one UID in VEVENT"
                  fi
                  for u in $cal_uid ; do 
                     if [ -n "${uid_list[$u]}" ]; then
                        new_uid="$(uuidgen)"
                        log_msg "$TYPE" "INFO: found double uid; creating new one"
                        if [[ $DEBUG -eq 1 ]]; then
                           log_msg "$TYPE" "DEBUG: old uid: $u"
                           log_msg "$TYPE" "DEBUG: new uid: $new_uid"
                        fi
                        sed -i "0,/^UID:$u/{s/$u/$new_uid/}" "${UID_TEST_FILE}"
                        uid_list["$new_uid"]='1'
                     else
                        uid_list["$u"]='1'
                     fi
                  done

                  cat "${UID_TEST_FILE}" >> import-${MBOXNAME}.${SUFFIX}
                  rm "${UID_TEST_FILE}"

                  # test upload if strict checking is requested
                  if [ "$CHECK_ITEMS" -eq 1 ]; then
                     # backup calendar
                     if [ -e "import-${MBOXNAME}.${SUFFIX}" ]; then
                       cp "import-${MBOXNAME}.${SUFFIX}" "import-${MBOXNAME}.${SUFFIX}.bak"
                     fi
                     rebuild_calendar "import-${MBOXNAME}.${SUFFIX}"

                     import_status_cal="$(do_curl_CALENDAR "import-${MBOXNAME}.${SUFFIX}" no_priv)"
                     log_msg "$TYPE" "Import Status: $(echo "$import_status_cal" | tail -1)"

                     # restore calendar
                     if [ -e "import-${MBOXNAME}.${SUFFIX}.bak" ]; then
                        mv "import-${MBOXNAME}.${SUFFIX}.bak" "import-${MBOXNAME}.${SUFFIX}"
                     else
                        rm "import-${MBOXNAME}.${SUFFIX}"
                     fi

                     if [[ "$(echo "$import_status_cal" | tail -1)" != 'OK' ]]; then
                        cat "${STRIPFILE}.${SUFFIX}" >> \
                           "${RAMDISK_LOCATION}/${FAILED_ITEMS_FOLDER}/orig-${MBOXNAME}.${SUFFIX}"
                        rm -f "${STRIPFILE}.${SUFFIX}"
                        log_msg "$TYPE" 'WARN: skipping import of calendar item'
                     fi
                  fi
               elif [[ "${TYPE}" = "CONTACT" ]]; then
                  import_status_contact='OK'  # set default
                  # change mboxname if mailbox has changed its type
                  if [[ "$FIRSTTYPE" != "$TYPE" ]] ; then
                     log_msg "${TYPE}" "RENAME FOLDER ${MBOXNAME} -> ${MBOXNAME}_B"
                     MBOXNAME="${MBOXNAME}_B"
                     FPATH="${FPATH//\//_B/}"
                  fi
                  ## create folder
                  if [ -z "${created_folders["${TYPE}:${FPATH}${MBOXNAME}"]}" ]; then
                     ${TOOL_LOCATION}/create-folder.py -u ${DEST_USER} -f "${FPATH}${MBOXNAME}" -t ${ipf_types[$TYPE]}
                     created_folders["${TYPE}:${FPATH}${MBOXNAME}"]='1'
                  fi
                  # remember mboxname for counting items
                  MBOXNAME_CONTACT="$MBOXNAME"

                  VCFNAME="`grep '^UID:' ${STRIPFILE}.${SUFFIX} | sed -e 's#^UID:##' -e 's#[[:space:]]##'`"
                  if [ -z "$VCFNAME" ] ; then
                     VCFNAME="$(/usr/bin/uuidgen)"
                  fi
                  # added: perl -p00e 's/=\r?\n//g' | perl -p00e 's/=3D\r?\n//g' to fix errors in rus
                  # rewrite unknown TYPE POSTAL to TYPE OTHER
                  sed ':a;N;$!ba;s/=\n//g' ${STRIPFILE}.${SUFFIX} | \
                     perl -MMIME::QuotedPrint -ne 'if ($_ =~ /QUOTED-PRINTABLE/) { print $_ ; } else { print decode_qp($_); }' | \
                     perl -p00e 's/\r?\n //g' | \
                     perl -p00e 's/=\r?\n//g' | perl -p00e 's/=3D\r?\n//g' | \
                     sed -e 's#DT\(.*\);TZID=.*:\(.*\)#DT\1:\2Z#g' | \
                     sed -e 's#;TYPE=POSTAL#;TYPE=OTHER#gi' | \
                     grep -vf ${TOOL_LOCATION}/cgp-attribute-strip.txt \
                     > "import-${MBOXNAME}-${VCFNAME}.${SUFFIX}"
                  # Add FN if no X-CN or FN exists (which breaks zarafa-sabre)
                  if ! egrep -q '^FN:|^EMAIL.*X-CN=' "import-${MBOXNAME}-${VCFNAME}.${SUFFIX}" ; then
                     sed -i 's/^\(VERSION:2.1\)$/\1\nFN:Not Named/' "import-${MBOXNAME}-${VCFNAME}.${SUFFIX}"
                  fi
                  # upload contact - compare and count results later
                  do_curl_CONTACT "import-${MBOXNAME}-${VCFNAME}.${SUFFIX}"
               elif [[ "${TYPE}" = "GROUP" ]]; then
                  VGFNAME="`grep '^UID:' ${STRIPFILE}.${SUFFIX} | sed -e 's#^UID:##' -e 's#[[:space:]]##'`"
                  if [ -z "$VGFNAME" ] ; then
                     VGFNAME="$(/usr/bin/uuidgen)"
                  fi
                  # move vgroup away, so that we can send it per mail
                  mv "${STRIPFILE}.${SUFFIX}" "${RAMDISK_LOCATION}/${FAILED_ITEMS_FOLDER}/import-${MBOXNAME}-${VGFNAME}.${SUFFIX}"
               elif [[ "${TYPE}" = "TASK" ]]; then
                  import_status_task='OK'  # set default
                  # change mboxname if mailbox has changed its type
                  if [[ "$FIRSTTYPE" != "$TYPE" ]] ; then
                     log_msg "${TYPE}" "RENAME FOLDER ${MBOXNAME} -> ${MBOXNAME}_A"
                     MBOXNAME="${MBOXNAME}_A"
                     FPATH="${FPATH//\//_A/}"
                  fi
                  ## create folder
                  if [ -z "${created_folders["${TYPE}:${FPATH}${MBOXNAME}"]}" ]; then
                     ${TOOL_LOCATION}/create-folder.py -u ${DEST_USER} -f "${FPATH}${MBOXNAME}" -t ${ipf_types[$TYPE]}
                     created_folders["${TYPE}:${FPATH}${MBOXNAME}"]='1'
                  fi
                  MBOXNAME_TASK="$MBOXNAME"

                  TASKNAME="`grep '^UID:' ${STRIPFILE}.${SUFFIX} | sed -e 's#^UID:##'`"
                  sed ':a;N;$!ba;s/=\n//g' ${STRIPFILE}.${SUFFIX} | \
                     perl -MMIME::QuotedPrint -ne 'if ($_ =~ /QUOTED-PRINTABLE/) { print $_ ; } else { print decode_qp($_); }' | \
                     perl -p00e 's/\r?\n //g' | sed -e 's#DT\(.*\);TZID=.*:\(.*\)#DT\1:\2Z#g' | \
                     grep -vf ${TOOL_LOCATION}/cgp-attribute-strip.txt > \
                     "import-${MBOXNAME}-${TASKNAME}.${SUFFIX}"
                  rebuild_calendar "import-${MBOXNAME}-${TASKNAME}.${SUFFIX}"
                  # private items need special treatment:
                  # import twice: first public, then private (after checking and counting results)
                  if grep -q -i '^CLASS:PRIVATE' "import-${MBOXNAME}-${TASKNAME}.${SUFFIX}" ; then
                     cp "import-${MBOXNAME}-${TASKNAME}.${SUFFIX}" "import-${MBOXNAME}-${TASKNAME}.${SUFFIX}.private"
                  fi
                  sed -i '/^CLASS:/d' "import-${MBOXNAME}-${TASKNAME}.${SUFFIX}"
                  # upload task - compare and count results later
                  do_curl_TASK "import-${MBOXNAME}-${TASKNAME}.${SUFFIX}"
               fi
               # register folder if necessary and increase element count
               if [ -z "${used_folders["${MBOXNAME}"]}" ]; then
                  used_folders["${MBOXNAME}"]='0'
               fi
               #let used_folders["${MBOXNAME}"]=${used_folders["${MBOXNAME}"]}+1
            else
               rm -f ${STRIPFILE}.${SUFFIX}
            fi
         fi
      done

      # upload final calendar file
      if [ -e "import-${MBOXNAME_CALENDAR}.cal.ics" ]; then
         rebuild_calendar "import-${MBOXNAME_CALENDAR}.cal.ics"
         # count calendar items
         calendar_count="$(grep -c BEGIN:VEVENT "import-${MBOXNAME_CALENDAR}.cal.ics")"
         let used_folders["${MBOXNAME_CALENDAR}"]=${used_folders["${MBOXNAME_CALENDAR}"]}+${calendar_count}
         do_curl_CALENDAR "import-${MBOXNAME_CALENDAR}.cal.ics"
      fi
      wait
      # count failed calendar item
      if [ -f $failed_cal_items ]; then
         failed_counter="$(cat $failed_cal_items | wc -l)"
         if [ "$failed_counter" -gt 0 ]; then
            let used_folders["${MBOXNAME_CALENDAR}"]=${used_folders["${MBOXNAME_CALENDAR}"]}-"$failed_counter"
            log_msg 'MIGRATION' "WARN: failed items: ${MBOXNAME_CALENDAR}: $failed_counter"
         fi
      fi

      # check contacts list
      contact_count="$(ls -1 import-*.vcf 2>/dev/null | wc -l)"
      if [[ "$contact_count" -gt 0 ]]; then
         used_folders["${MBOXNAME_CONTACT}"]="$contact_count"
         ls -1 import-*.vcf | sort > contact_files
         # <td><a href="/zarafa-sabre/addressbooks/st000003/Kontakte_in_der_Inbox/import-Kontakte_in_der_Inbox-555188919.6.herbie%40po2.uni-stuttgart.de.vcf">import-Kontakte_in_der_Inbox-555188919.6.herbie@po2.uni-stuttgart.de.vcf</a></td>
         curl --retry 3 -sS -u ${DEST_USER}:notused "http://${VCARD_IP}/zarafa-sabre/addressbooks/${DEST_USER}/${MBOXNAME_CONTACT}/" | \
            grep -v 'img src=' | grep '.vcf' | sed -r 's#^.*<a href="([^"]+)">([^<]+)</a>.*$#\2#' | sort > upload_contact_files
         get_status curl
         while read file ; do
            if [ -n "$file" ]; then
               cp "$file" ${RAMDISK_LOCATION}/${FAILED_ITEMS_FOLDER}/
               let used_folders["${MBOXNAME_CONTACT}"]=${used_folders["${MBOXNAME_CONTACT}"]}-1
               log_msg 'MIGRATION' "ERROR: failed to upload vcf. ${DEST_USER}: ${file}"
            fi
         done <<< "$(join -v1 contact_files upload_contact_files)"
      fi

      # check tasks list
      task_count="$(ls -1 import-*.task.ics 2>/dev/null | wc -l)"
      if [[ "$task_count" -gt 0 ]]; then
         used_folders["${MBOXNAME_TASK}"]="$task_count"

         # do comparison check here
         grep -h -i ^SUMMARY import-*.task.ics | \
            sed -e 's#\\"##g' -e 's#"##g' -e 's# $##g' | sort > tasklist.src
         curl --retry 3 -sS -u "$ICAL_USER" "http://${ICAL_IP}:${ICAL_PORT}/ical/${DEST_USER}/${MBOXNAME_TASK}/" | \
            grep -i ^SUMMARY | sed -e 's#\\"##g' -e 's#"##g' -e 's# $##g' | sort > tasklist.dst
         dos2unix -q tasklist.dst
         diff -p tasklist.src tasklist.dst | grep '^- SUMMARY' | \
         sed -e '/^- SUMMARY:$/d' -e 's#- ##g' | uniq | while read line; do
            log_msg 'MIGRATION' "ERROR: failed to upload task. ${DEST_USER}: ${line}"
            let used_folders["${MBOXNAME_TASK}"]=${used_folders["${MBOXNAME_TASK}"]}-1
            grep -h "$line" import-*.task.ics -B40 -A40 | \
               sed '/^BEGIN:VCALENDAR/,/^END:VCALENDAR/!d' >> \
               "${RAMDISK_LOCATION}/${FAILED_ITEMS_FOLDER}"/tasks
         done
         if [ -f "${RAMDISK_LOCATION}/${FAILED_ITEMS_FOLDER}"/tasks ]; then
            pushd "${RAMDISK_LOCATION}/${FAILED_ITEMS_FOLDER}" >/dev/null
            csplit -q tasks "/^BEGIN:VCALENDAR/" {*}
               rm -f xx00
               for i in xx*; do
                  if [ -f $i ]; then
                     mv $i "${MBOXNAME_TASK}-${i}.task.ics"
                  else
                     log_msg 'MIGRATION' "WARN: failed to extract VCALENDAR from ${MBOXNAME_TASK}"
                  fi
               done
             rm -f tasks
             popd >/dev/null
         fi
         # import private items
         for file in import-*.task.ics.private ; do
            if [ -e $file ]; then
               do_curl_TASK "$file"
               get_status curl
            fi
         done
      fi

      popd 2>&1 >/dev/null

      rm -f ${RAMDISK_LOCATION}/${MBOXFILE}/*.mbox
      log_msg "${TYPE}" "END ${MBOXFILE}"
      if [[ "${DO_NOTES}" = "1" ]]; then
         NOTE_COUNT=$(grep -c '^X-MAPI-Message-Class: IPM.StickyNote' "${MBOXFILE}")
         if [ "$NOTE_COUNT" -gt 0 ] ; then
            log_msg 'NOTES' "START ${MBOXFILE}"
            [[ $DEBUG -eq 1 ]] && echo ${TOOL_LOCATION}/import-mbox.py "${DEST_USER}" 'IPF.StickyNote' "${MBOXFILE}"
            # notes mbox files may contain mails without X-MAPI-Message-Class. Count every mail.
            NOTE_COUNT=$(grep -c '^From ' "${MBOXFILE}")
            ${TOOL_LOCATION}/import-mbox.py "${DEST_USER}" 'IPF.StickyNote' "${MBOXFILE}"
            get_status 'import-mbox.py'
            log_msg 'NOTES' "END ${MBOXFILE}"
            # register folder if necessary and increase element count
            NOTESNAME="$(basename ${MBOXFILE%.mbox})"
            if [ -z "${used_folders["${NOTESNAME}"]}" ]; then
               used_folders["${NOTESNAME}"]='0'
            fi
            let used_folders["${NOTESNAME}"]=${used_folders["${NOTESNAME}"]}+$NOTE_COUNT
         fi
      fi
      TYPE="NONE"
      DO_SKIP=0
      # deregister mailbox if it wasn't used
      if [ "${used_folders["${MBOXNAME}"]}" -eq 0 ]; then
         unset used_folders["${MBOXNAME}"]
      fi
   done <<< "$MBOXFILE_LIST"

   if [[ "${DO_FOLDER}" = "1" ]]; then
      log_msg 'IMAPSYNC' "START ${source_account}"
      #[[ $DEBUG -eq 1 ]] && echo ${TOOL_LOCATION}/import-mbox.py "${DEST_USER}" "${MBOXFILE}"
      #${TOOL_LOCATION}/import-mbox.py "${DEST_USER}" "${MBOXFILE}"
      #get_status 'import-mbox.py'
      [[ $DEBUG -eq 1 ]] && type do_imapsync
      do_imapsync $source_account
      log_msg 'IMAPSYNC' "END ${source_account}"
   else
      # give zarafa-server some time to import items
      sleep 30
   fi
   if [[ "${DO_RULES}" = "1" ]]; then
      log_msg 'RULES' "START ${DEST_USER}"
      # remove Password line from settings as it may contain funny characters
      grep -v '^ Password = ' "${source_account%%@*}.macnt/account.settings" > "${RAMDISK_LOCATION}/accout.settings"
      if ! do_import_rules "${RAMDISK_LOCATION}/accout.settings" ; then
         log_msg 'RULES' "converting rules failed"
         if [[ "$FAIL_ON_RULES" -eq 1 ]]; then
            STATUS=1
         fi
      fi
      log_msg 'RULES' "END ${DEST_USER}"
   fi

   # Now, as we assume everything else has been imported, we import the permissions
   if [[ "${DO_PERMISSIONS}" = "1" ]]; then
      log_msg 'PERMISSIONS' "START PERMISSIONS OF ${DEST_USER}"
      grep Access ${source_account%%@*}.macnt/account.info | sed -e 's#^ \(.*\) = .*Access={\(.*\)};Box.*#\1\t\2#' -e 's#"##g' -e 's#^#[PERMISSIONS]\t#g'
      grep Access ${source_account%%@*}.macnt/account.info | sed -e 's#^ \(.*\) = .*Access={\(.*\)};Box.*#\1\t;\2#' -e 's#"##g' -e 's#;$##g' > ${RAMDISK_LOCATION}/${DEST_USER}.perm
      sed -e 's#.*\t;##g' -e 's#=l[rswipcda]*##g' -e 's#;#\n#' ${RAMDISK_LOCATION}/${DEST_USER}.perm | sort | uniq | while read PERMUSER; do
         PERMSTRING=""
         grep -i ${PERMUSER} ${RAMDISK_LOCATION}/${DEST_USER}.perm | awk '{ print $1 }' | while read FOLDER; do
            PERMS="`grep -i ${PERMUSER} ${RAMDISK_LOCATION}/${DEST_USER}.perm | grep $FOLDER | sed \"s#.*${PERMUSER}=\(l[rswipcda]*\).*#\1#g\"`"
            if [[ "$PERMS" = "lrswipcda" ]]; then
               ZPERMS="fullcontrol"
            elif [[ "$PERMS" = "lrswipcd" ]]; then
               ZPERMS="owner"
            elif [[ "$PERMS" = "lrsip" || "$PERMS" = "lrswip" || "$PERMS" = "lrps" ]]; then
               ZPERMS="secretary"
            else
               ZPERMS="readonly"
            fi
            if [[ "`echo $FOLDER | grep -i cal | wc -l`" -gt "0" ]]; then
               PERMSTRING="${PERMSTRING} --calendar ${ZPERMS}"
            elif [[ "`echo $FOLDER | grep -i contact | wc -l`" -gt "0" ]]; then
               PERMSTRING="${PERMSTRING} --contacts ${ZPERMS}"
            elif [[ "`echo $FOLDER | grep -i task | wc -l`" -gt "0" ]]; then
               PERMSTRING="${PERMSTRING} --tasks ${ZPERMS}"
            elif [[ "`echo $FOLDER | grep -i inbox | wc -l`" -gt "0" ]]; then
               PERMSTRING="${PERMSTRING} --inbox ${ZPERMS}"
            fi
            echo $PERMSTRING > ${RAMDISK_LOCATION}/${DEST_USER}.$PERMUSER.perm
         done
         echo /usr/bin/zarafa-mailbox-permissions --update-delegate "${PERMUSER}" "`cat ${RAMDISK_LOCATION}/${DEST_USER}.${PERMUSER}.perm`" "${DEST_USER}" >> ${RAMDISK_LOCATION}/all_permissions.sh
         rm -f ${RAMDISK_LOCATION}/${DEST_USER}.${PERMUSER}.perm
      done
      chmod u+x ${RAMDISK_LOCATION}/all_permissions.sh
      sh ${RAMDISK_LOCATION}/all_permissions.sh
      get_status all_permissions.sh

      rm -f ${RAMDISK_LOCATION}/${DEST_USER}.perm
      log_msg 'PERMISSIONS' "END PERMISSIONS OF ${DEST_USER}"
   fi

   ## wait for background processes
   wait
   log_msg 'MIGRATION' "FINISHED PROCESSING user ${source_account%%@*} -> ${DEST_USER}"

   popd 2>&1 >/dev/null
done # for loop

# check and fix contacts, calendar and tasks items
log_msg 'MIGRATION' "Starting zarafa-fsck"
zarafa-fsck -u st000003 --autofix yes --autodel no --acceptdisclaimer | grep -A 19 ^Statistics
log_msg 'MIGRATION' "Finished zarafa-fsck"

log_msg 'MIGRATION' "DONE user $DEST_USER"

log_msg 'REVIEW' "START REVIEW PROCESS for $DEST_USER"

# calculate the new elements in the zarafa folders:
update_zarafa_folder_list

## check if all elements were accepted by zarafa
for name in "${!used_folders[@]}"; do
   if [ -z "${zarafa_folders[$name]}" ] ; then
      if [ "${used_folders[$name]}" -gt 0 ]; then
         log_msg 'REVIEW' "ERROR: $name doesn't exist in zarafa_folders (should be: ${used_folders[$name]})!"
         if [ "$CHECK_COUNT" -eq 1 ]; then 
            STATUS=1
         fi
      fi
   elif [ "${used_folders[$name]}" -gt "${zarafa_folders[$name]}" ]; then
      log_msg 'REVIEW' "ERROR: $name ${used_folders[$name]} > ${zarafa_folders[$name]} (uploaded : stored)"
      if [ "$CHECK_COUNT" -eq 1 ]; then 
        STATUS=1
      fi
   elif [ "${used_folders[$name]}" -lt "${zarafa_folders[$name]}" ]; then
      log_msg 'REVIEW' "WARN: $name ${used_folders[$name]} < ${zarafa_folders[$name]} (uploaded : stored)"
   fi
done

## send items by email which failed import to zarafa
failed_items_size="$(du -s "${RAMDISK_LOCATION}/${FAILED_ITEMS_FOLDER}" | awk '{ print $1 }')"
attachments=''
if [[ "$(ls -1 "${RAMDISK_LOCATION}/${FAILED_ITEMS_FOLDER}" 2>/dev/null | wc -l)" -gt 0 ]] ; then
   INFO_MAIL_RCPT=${INFO_MAIL_RCPT:-"${DEST_USER}@${INFO_MAIL_RCPT_DOMAIN}"}

   pushd "${RAMDISK_LOCATION}/${FAILED_ITEMS_FOLDER}" >/dev/null
   # cleanup
   ics_counter="0"
   ics_max="$(ls -1 *.ics 2>/dev/null | wc -l)"
   for x in *.ics ; do
      for y in *.ics ; do
         if [ "$x" != "$y" ]; then
            if cmp -s "$x" "$y" ; then
               rm "$y"
            fi
         fi
      done
      if [[ $ics_max -gt 50 ]]; then
         echo -en "\rcomparing file ${ics_counter} from ${ics_max}"
      fi
      ics_counter="$(($ics_counter + 1))"
   done
   if [[ $ics_max -gt 50 ]]; then
      echo
   fi

   # concat calendar files to a big one
   ls -1 * 2>/dev/null | grep .ics | sed -n -e 's/^\(import-.*\)-xx[0-9]*.ics/\1/pg' | \
     sort | uniq | while read mbox; do
      echo -e 'BEGIN:VCALENDAR\nVERSION:2.0\nMETHOD:PUBLISH' > ${mbox}.ics
      cat ${mbox}-xx* >> ${mbox}.ics
      echo -e "END:VCALENDAR" >> ${mbox}.ics
      rm -f ${mbox}-xx*
   done
   popd >/dev/null

   # send or send not mail
   if [[ "$SEND_INFO_MAIL" -eq '1' ]]; then
      if [[ "$failed_items_size" -lt 20000 ]]; then
         for f in "${RAMDISK_LOCATION}/${FAILED_ITEMS_FOLDER}/"* ; do
            attachments="$attachments -a $f"
         done
         echo "$INFO_MAIL_BODY" | mailx -s "$INFO_MAIL_SUBJECT" -r "$INFO_MAIL_SENDER" $attachments "$INFO_MAIL_RCPT"
         # files are too big send in chunks
         log_msg 'SENDMAIL' "Send $failed_items_size KBytes as email attachment"
      else
         # files are too big send in chunks
         log_msg 'SENDMAIL' "WARNING: Must send $failed_items_size KBytes as email attachment"
         for f in "${RAMDISK_LOCATION}/${FAILED_ITEMS_FOLDER}/"* ; do
            echo "$INFO_MAIL_BODY" | mailx -s "$INFO_MAIL_SUBJECT" -r "$INFO_MAIL_SENDER" \
                                        -a $f "$INFO_MAIL_RCPT"
         done
      fi
   fi
fi

log_msg 'REVIEW' "FINISHED REVIEW PROCESS for $DEST_USER"

## necessary ???
log_msg 'MIGRATION' 'DESTINATION REPORT'
LANG="$MY_LANG" ${TOOL_LOCATION}/list-folder-size.py ${DEST_USER}

if [ "${#zarafa_folders[@]}" -gt 0 ]; then
   log_msg 'MIGRATION' 'ITEMS IMPORTED TO ZARAFA'
   for name in "${!zarafa_folders[@]}"; do
      if [ "${zarafa_folders[$name]}" -gt 0 ]; then
         printf "%-40s %5d\n" "${name}:" ${zarafa_folders[$name]}
      fi
   done
else
   log_msg 'MIGRATION' 'NO ITEMS IMPORTED TO ZARAFA'
fi


## get errors from pipe
ERRORS=0
while read line; do
   if [ "$line" == 'error' ]; then
      ERRORS=$(( $ERRORS + 1 ))
   fi
done < "${RAMDISK_LOCATION}/${DEST_USER}.errors"
if [ "$ERRORS" -gt 0 ]; then
   log_msg 'MIGRATION' "FAILED: Migration of ${DEST_USER} failed with $ERRORS"
   if [ "$STATUS" -eq 0 ]; then
      STATUS=1
   fi
fi
rm "${RAMDISK_LOCATION}/${DEST_USER}.errors"

popd 2>&1 >/dev/null

if [ "${CLEAN_RAMDISK_AFTER_RUN}" = 1 ]; then
   clean_ramdisk
fi

exit $STATUS
