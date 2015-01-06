#!/bin/bash
perl_packages="ExtUtils::MakeMaker Parse::RecDescent Digest::MD5 Term::ReadKey IO::Socket:SSL Net::SSLeay Mail::IMAPClient"

for i in $perl_packages; do
	echo perl -MCPAN -e "install($i)"
	perl -MCPAN -e "install($i)"
done
mkdir imapsync
pushd imapsync
	wget --no-check-certificate https://fedorahosted.org/released/imapsync/imapsync-1.584.tgz
	tar xvfpz imapsync-1.584.tgz
	rm -f imapsync-1.584.tgz
	pushd imapsync-1.584
		perl -c imapsync
		make install
	popd
popd
