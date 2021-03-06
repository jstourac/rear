# linux-functions.sh
#
# linux functions for Relax-and-Recover
#
# This file is part of Relax-and-Recover, licensed under the GNU General
# Public License. Refer to the included COPYING for full text of license.

# The way how we use bash with lots of (nested) functions and read etc. seems to trigger a bash
# bug that causes leaked file descriptors. lvm likes to complain about that but since we
# cannot fix the bash we suppress these lvm warnings, see
# http://osdir.com/ml/bug-bash-gnu/2010-04/msg00080.html
# http://stackoverflow.com/questions/2649240/bash-file-descriptor-leak
# http://bugs.debian.org/cgi-bin/bugreport.cgi?bug=466138
export LVM_SUPPRESS_FD_WARNINGS=1

# check if udev is available in a sufficiently recent version
# has_binary succeeds when one of its arguments exists
# newer systems (e.g. SLES11) have udevadm
# older systems (e.g. SLES10 or RHEL 4) have udevtrigger udevsettle udevinfo or udevstart
function have_udev () {
    test -d /etc/udev/rules.d && has_binary udevadm udevtrigger udevsettle udevinfo udevstart && return 0
    return 1
}

# try calling 'udevadm trigger' or 'udevtrigger' or fallback
# but waiting for udev and "kicking udev" both miss the point
# see https://github.com/rear/rear/issues/791
function my_udevtrigger () {
    # first try the most current way, newer systems (e.g. SLES11) have 'udevadm trigger'
    has_binary udevadm && udevadm trigger $@ && return 0
    # then try an older way, older systems (e.g. SLES10) have 'udevtrigger'
    has_binary udevtrigger && udevtrigger $@ && return 0
    # as first fallback do what start_udev does on RHEL 4
    if has_binary udevstart ; then
        local udevd_pid=$( pidof -x udevd )
        test "$udevd_pid" && kill $udevd_pid
        udevstart </dev/null &>/dev/null && return 0
    fi
    # as final fallback just wait a bit and hope for the best
    sleep 10
}

# try calling 'udevadm settle' or 'udevsettle' or fallback
# but waiting for udev and "kicking udev" both miss the point
# see https://github.com/rear/rear/issues/791
function my_udevsettle () {
    # first try the most current way, newer systems (e.g. SLES11) have 'udevadm settle'
    has_binary udevadm && udevadm settle $@ && return 0
    # then try an older way, older systems (e.g. SLES10) have 'udevsettle'
    has_binary udevsettle && udevsettle $@ && return 0
    # as first fallback re-implement udevsettle for older systems
    if [ -e /sys/kernel/uevent_seqnum ] && [ -e /dev/.udev/uevent_seqnum ] ; then
        local tries=0
        while [ "$( cat /sys/kernel/uevent_seqnum )" = "$( cat /dev/.udev/uevent_seqnum )" ] && [ "$tries" -lt 10 ] ; do
            sleep 1
            let tries=tries+1
        done
        return 0
    fi
    # as final fallback just wait a bit and hope for the best
    sleep 10
}

# call 'udevadm info' or 'udevinfo'
function my_udevinfo () {
    # first try the most current way, newer systems (e.g. SLES11) have 'udevadm info'
    if has_binary udevadm ; then
        udevadm info "$@"
        return 0
    fi
    # then try an older way, older systems (e.g. SLES10) have 'udevinfo'
    if has_binary udevinfo ; then
        udevinfo "$@"
        return 0
    fi
    # no fallback
    return 1
}

# find out which are the storage drivers to use on this system
# returns a list of storage drivers on STDOUT
# optionally $1 specifies the directory where to search for
# drivers files
function FindStorageDrivers () {
    if (( ${#STORAGE_DRIVERS[@]} == 0 )) ; then
        if ! grep -E 'kernel/drivers/(block|firewire|ide|ata|md|message|scsi|usb/storage)' /lib/modules/$KERNEL_VERSION/modules.builtin ; then
            Error "FindStorageDrivers called but STORAGE_DRIVERS is empty and no builtin storage modules found"
        fi
    fi
    {
        while read module junk ; do
            IsInArray "$module" "${STORAGE_DRIVERS[@]}" && echo $module
        done < <(lsmod)
        find ${1:-$VAR_DIR/recovery} -name storage_drivers -exec cat '{}' \; 2>/dev/null
    } | grep -v -E '(loop)' | sort -u
    # blacklist some more stuff here that came in the way on some systems
    return 0
    # always return 0 as the grep return code is meaningless
}

# Copy binaries given in $2 $3 ... to directory $1
function BinCopyTo () {
    local destdir="$1" binary=""
    test -d "$destdir" || Error "BinCopyTo destination '$destdir' is not a directory"
    while (( $# > 1 )) ; do
        shift
        binary="$1"
        # continue with the next one if a binary is empty or contains only blanks
        # there must be no double quotes for the test argument because test " " results true
        test $binary || continue
        if ! cp $verbose --archive --dereference --force "$binary" "$destdir" >&2 ; then
            Error "BinCopyTo failed to copy '$binary' to '$destdir'"
        fi
    done
}

# Resolve dynamic library dependencies. Returns a list of symbolic links
# to shared objects and shared object files for the binaries in $@.
# This is the function copied from mkinitrd off SUSE 9.3
function SharedObjectFiles () {
    has_binary ldd || Error "SharedObjectFiles failed because there is no ldd binary"

    # Default ldd output (when providing more than one argument) has 5 cases:
    #  1. Line: "file:"                            -> file argument
    #  2. Line: "	lib =>  (mem-addr)"            -> virtual library
    #  3. Line: "	lib => not found"              -> print error to stderr
    #  4. Line: "	lib => /path/lib (mem-addr)"   -> print $3
    #  5. Line: "	/path/lib (mem-addr)"          -> print $1
    local -a initrd_libs=( $( ldd "$@" | awk '
            /^\t.+ => not found/ { print "WARNING: Dynamic library " $1 " not found" > "/dev/stderr" }
            /^\t.+ => \// { print $3 }
            /^\t\// { print $1 }
        ' | sort -u ) )

    ### FIXME: Is this still relevant today ? If so, make it more specific !

    # Evil hack: On some systems we have generic as well as optimized
    # libraries, but the optimized libraries may not work with all
    # kernel versions (e.g., the NPTL glibc libraries don't work with
    # a 2.4 kernel). Use the generic versions of the libraries in the
    # initrd (and guess the name).
#	local lib= n= optimized=
#	for ((n=0; $n<${#initrd_libs[@]}; n++)); do
#		lib=${initrd_libs[$n]}
#		optimized="$(echo "$lib" | sed -e 's:.*/\([^/]\+/\)[^/]\+$:\1:')"
#		lib=${lib/$optimized/}
#		if [ "${optimized:0:3}" != "lib" -a -f "$lib" ]; then
#			#echo "[Using $lib instead of ${initrd_libs[$n]}]" >&2
#			initrd_libs[$n]="${lib/$optimized/}"
#		fi
#		echo Deoptimizing "$lib" >&2
#	done

    local lib="" link=""
    for lib in "${initrd_libs[@]}" ; do
        lib="${lib:1}"
        while [ -L "/$lib" ] ; do
            echo $lib
            link="$( readlink "/$lib" )"
            case "$link" in
                (/*) lib="${link:1}" ;;
                (*)  lib="${lib%/*}/$link" ;;
            esac
        done
        echo $lib
        echo $lib >&2
    done | sort -u
}

# Provide a shell, with custom exit-prompt and history
function rear_shell () {
    local prompt=$1
    local history=$2
    # Set fallback exit prompt:
    test "$prompt" || prompt="Are you sure you want to exit the Relax-and-Recover shell ?"
    # Set some history:
    local histfile="$TMP_DIR/.bash_history"
    echo "exit" >$histfile
    test "$history" && echo -e "exit\n$history" >$histfile
    # Setup .bashrc:
    local bashrc="$TMP_DIR/.bashrc"
    cat <<EOF >$bashrc
export PS1="rear> "
ask_exit() {
    read -p "$prompt " REPLY
    if [[ "\$REPLY" =~ ^[Yy1] ]] ; then
        \exit
    fi
}
rear() {
    echo "ERROR: You cannot run rear from within the Relax-and-Recover shell !" >&2
}
alias exit=ask_exit
alias halt=ask_exit
alias poweroff=ask_exit
alias reboot=ask_exit
alias shutdown=ask_exit
cd $VAR_DIR
EOF
    # Run 'bash' with the original STDIN STDOUT and STDERR when 'rear' was launched by the user
    # to get input from the user and to show output to the user (cf. _input-output-functions.sh):
    HISTFILE="$histfile" bash --noprofile --rcfile $bashrc 0<&6 1>&7 2>&8
}

# Return the filesystem name related to a path
function filesystem_name () {
    local path=$1
    local fs=$(df -Pl "$path" | awk 'END { print $6 }')
    if [[ -z "$fs" ]]; then
        echo "/"
    else
        echo "$fs"
    fi
}

