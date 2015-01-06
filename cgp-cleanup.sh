#!/bin/bash 
### CommunigatePro Import scripts
### 2014 Zarafa

# Importing config
. ./config.sh

if [ "${CLEAN_RAMDISK_AFTER_RUN}" = 1 ]; then
	umount -f ${RAMDISK_ROOT}/*
	rm -rf ${RAMDISK_ROOT}/*
fi
