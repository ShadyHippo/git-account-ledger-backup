# shellcheck shell=bash
# Wall-clock scheduling without date parsing.
#
# busybox date has no reliable "next 03:15" parser, so this is pure arithmetic
# on the current clock. It drifts across a DST change by at most an hour, which
# is irrelevant for a nightly job.

valid_hhmm() {
    [[ ${1:-} =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]
}

# seconds_until HH:MM -> 1..86400, how long to sleep before that time next comes
seconds_until() {
    local t=$1 h m cur want d
    h=${t%%:*}
    m=${t##*:}
    h=$((10#$h))
    m=$((10#$m))
    cur=$(( 10#$(date +%H) * 3600 + 10#$(date +%M) * 60 + 10#$(date +%S) ))
    want=$(( h * 3600 + m * 60 ))
    d=$(( want - cur ))
    [ "$d" -le 0 ] && d=$(( d + 86400 ))
    printf '%s' "$d"
}
