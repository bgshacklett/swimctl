#!/bin/sh


# lbu_commit: friendlier wrapper around `lbu commit`
# Usage:
#   lbu_commit [-d] [-e] [-n] [-p PASSWORD] [-q] [-v] [media|/media/NAME]
# Notes:
#   - If LBU_BACKUPDIR is set, the positional media arg is optional.
#   - If you pass a full path (/media/NAME or any absolute dir), the wrapper
#     sets LBU_BACKUPDIR to that path so lbu won’t misinterpret it as a media name.

lbu_commit() {
    # Collect options to forward 1:1 to `lbu commit`
    _fwd_opts=
    _p_arg=
    OPTIND=1
    while getopts "denp:qv" _opt; do
        case "$_opt" in
            d|e|n|q|v) _fwd_opts="$_fwd_opts -$_opt" ;;
            p)         _p_arg=$OPTARG
                       _fwd_opts="$_fwd_opts -p $_p_arg" ;;
            \?)        echo "Usage: lbu_commit [-d] [-e] [-n] [-p PASSWORD] [-q] [-v] [media|/path]" >&2
                       return 2 ;;
        esac
    done
    shift $((OPTIND-1))

    # Decide destination:
    # 1) If a positional remains and starts with '/', treat it as a path.
    # 2) Else, if a positional remains, treat it as a media NAME.
    # 3) Else, rely on LBU_BACKUPDIR (must be set/valid).
    _arg="${1-}"

    if [ -n "$_arg" ] && [ "${_arg#/*}" != "$_arg" ]; then
        # Absolute path provided
        _dest="$_arg"
        shift
        # Sanity checks
        if [ ! -d "$_dest" ]; then
            echo "Error: destination path '$_dest' does not exist." >&2
            echo "Hint: mkdir -p '$_dest'  (or pass a media name like 'mmcblk1p1')" >&2
            return 2
        fi
        if [ ! -w "$_dest" ]; then
            echo "Warning: destination path '$_dest' is not writable; commit may fail." >&2
        fi
        # Call lbu with LBU_BACKUPDIR so it won’t treat the path as a media name
        # shellcheck disable=SC2086  # $_fwd_opts is intentionally word-split into separate args
        LBU_BACKUPDIR="$_dest" lbu commit $_fwd_opts
        return $?
    fi

    if [ -n "$_arg" ]; then
        # Media NAME (e.g. mmcblk1p1)
        _media="$_arg"
        shift
        # Check the expected mountpoint exists to preempt lbu’s vague usage
        _mnt="/media/$_media"
        if [ ! -d "$_mnt" ]; then
            # Redact `-p PASSWORD` from the hint string so the encryption
            # password isn't written to stderr/logs. We don't need the full
            # option string in the hint — just enough to be useful.
            _safe_opts="$(echo "$_fwd_opts" | sed 's/-p [^ ]*/-p ***/g')"
            echo "Error: mountpoint '$_mnt' does not exist." >&2
            echo "Hint: mkdir -p '$_mnt' and ensure the media can be mounted read/write." >&2
            echo "Alt:  LBU_BACKUPDIR=/media/$_media lbu_commit$_safe_opts" >&2
            return 2
        fi
        # shellcheck disable=SC2086  # $_fwd_opts is intentionally word-split
        lbu commit $_fwd_opts "$_media"
        return $?
    fi

    # No positional provided; rely on LBU_BACKUPDIR
    if [ -z "${LBU_BACKUPDIR-}" ]; then
        echo "Error: no media or path provided and LBU_BACKUPDIR is unset." >&2
        echo "Usage: lbu_commit [options] mmcblk1p1    # media NAME" >&2
        echo "   or: LBU_BACKUPDIR=/media/mmcblk1p1 lbu_commit [options]" >&2
        return 2
    fi
    if [ ! -d "$LBU_BACKUPDIR" ]; then
        echo "Error: LBU_BACKUPDIR='$LBU_BACKUPDIR' does not exist." >&2
        return 2
    fi
    if [ ! -w "$LBU_BACKUPDIR" ]; then
        echo "Warning: LBU_BACKUPDIR='$LBU_BACKUPDIR' is not writable; commit may fail." >&2
    fi

    # shellcheck disable=SC2086  # $_fwd_opts is intentionally word-split
    lbu commit $_fwd_opts
}

# Show changes to be committed
lbu status -a

# Ensure $BOOT is set
if [ -n "$BOOT" ]; then
    # Normalize: remove trailing slash, strip /media/ prefix
    BOOT_MEDIA=$(basename "${BOOT%/}")
else
    echo "Error: BOOT not set" >&2
    exit 2
fi

# Commit changes
lbu_commit -v -d "$BOOT_MEDIA"
