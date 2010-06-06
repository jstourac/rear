# 00_create_symlinks.sh
#
# create some symlinks for Relax & Recover
#
#    Relax & Recover is free software; you can redistribute it and/or modify
#    it under the terms of the GNU General Public License as published by
#    the Free Software Foundation; either version 2 of the License, or
#    (at your option) any later version.

#    Relax & Recover is distributed in the hope that it will be useful,
#    but WITHOUT ANY WARRANTY; without even the implied warranty of
#    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#    GNU General Public License for more details.

#    You should have received a copy of the GNU General Public License
#    along with Relax & Recover; if not, write to the Free Software
#    Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA  02110-1301  USA
#
#

pushd $ROOTFS_DIR >/dev/null
	
	ln -sf bin/init init
	ln -sf bin sbin
	ln -sf bin/bash bin/sh
	ln -sf true bin/pam_console_apply # RH/Fedora with udev needs this
	pushd usr >/dev/null
		ln -sf /bin bin
		ln -sf /lib lib
	popd >/dev/null
popd >/dev/null