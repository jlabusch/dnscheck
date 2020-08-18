#!/usr/bin/env bash

COL_DEBUG=35
COL_INFO=33
COL_ERR=31

function log(){
    if [ "$1" = '--color' ]; then
        echo -ne "\e[${2}m"
        shift 2
    fi
    printf "$(date)\t"
    echo $*
    echo -ne "\e[0m"
}

function pretty(){
    local IP=$(echo "$1" | cut -d, -f 1)
    local NAME=$(echo "$1" | cut -d, -f 2)
    local ORG=$(echo "$1" | cut -d, -f 3)
    local COUNTRY=$(echo "$1" | cut -d, -f 4)
    local CITY=$(echo "$1" | cut -d, -f 5)

    echo "$IP (org=\"${ORG:-unknown}\", name=\"${NAME:-unnamed}\") in ${CITY:-unknown}/${COUNTRY:-unknown}"
}

function run_dig(){
    local SERVER
    if [ -n "$1" ]; then
        SERVER="@$(echo "$1" | cut -d, -f 1)"
    fi
    
    dig +noall +answer $SERVER $DOMAIN | perl -p -e 's/^([^ ]+)(\s+)\d+\s+/$1$2/' | sort
}

# $1: $LINE
# $2: DNS server (optional)
function run_query_and_handle_match(){
    if echo "$2" | grep -q :; then
        log --color $COL_INFO "Skipping IPv6 server $2" >&2
        return 0
    fi

    local FILE=$(run_query $2)
    if echo "$FILE" | grep -E -q 'tmp$'; then
        create_match $FILE "$1"
    else
        update_match $FILE "$1"
    fi
}

# $1: foo.tmp
# $2: $LINE
function create_match(){
    log --color $COL_DEBUG "create_match($1)" >&2
    MODEL=${ANSWER_BASE}.model.${UNIQUE_COUNT}
    MATCH=${ANSWER_BASE}.match.${UNIQUE_COUNT}
    UNIQUE_COUNT=$(( $UNIQUE_COUNT + 1 ))

    mv -v $1 $MODEL >&2
    pretty "$2" >> $MATCH
}

# $1: foo.model.N which matched the last query
# $2: $LINE
function update_match(){
    #log "update_match($1)" >&2
    FILE=$(echo $1 | perl -p -e 's/model/match/')
    pretty "$2" >> $FILE
}

# $1: DNS server (optional)
#
# Run the dig and return the filename of any matching previous answers.
# The caller should then add this server's details to the correpsonding
# match file.
# If no match, the caller should create a new one.
function run_query(){
    #log --color $COL_DEBUG "run_query($1)" >&2
    local OUT=${ANSWER_BASE}.tmp
    run_dig $* > $OUT

    if grep -q $DOMAIN $OUT && grep -q -E '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' $OUT; then
        local SHA=$(sha1sum $OUT | awk '{print $1}')

        local i
        for i in ${ANSWER_BASE}.model.*; do
            if [ -f $i ] && [ $(sha1sum $i | awk '{print $1}') = $SHA ]; then
                echo $i
                rm -f $OUT
                return 0
            fi
        done

        echo $OUT
        return 1
    else
        log --color $COL_ERR "Treating output as error:" >&2
        cat $OUT >&2
        touch ${ANSWER_BASE}.model.err
        echo ${ANSWER_BASE}.model.err
        return 0
    fi
}

function main(){
    local SERVER_LIST_URL='https://public-dns.info/nameservers.csv'
    local SERVER_LIST=$(tempfile)
    curl -s $SERVER_LIST_URL | cut -d, -f 1,2,4,5,6 > $SERVER_LIST
    log "loaded $(wc -l < $SERVER_LIST) servers"

    local UNIQUE_COUNT=0
    local ANSWER_BASE=$(tempfile)
    run_query_and_handle_match ',system default,here,here,here'

    local CHECK_COL_LIST='ip_address,name,as_org,country_code,city'
    local LINE
    local COUNTRYOK
    local MATCH_COUNT=0
    local FAIL_COUNT=0
    while read -r LINE; do
        if [ -n "$CHECK_COL_LIST" ]; then
            if [ "$CHECK_COL_LIST" = "$LINE" ]; then
                unset CHECK_COL_LIST
                continue
            else
                log --color $COL_ERR "Error: file format has changed, expected columns to be"
                log --color $COL_ERR -e "\t\t\"$CHECK_COL_LIST\""
                log --color $COL_ERR -e "\tbut got"
                log --color $COL_ERR -e "\t\t\"$LINE\""
                exit 1
            fi
        fi

        COUNTRYOK=true
        if [ -n "$FILTER_COUNTRY" ]; then
            if [ "$(echo "$LINE" | cut -d, -f 4)" != "$FILTER_COUNTRY" ]; then
                COUNTRYOK=false
            fi
        fi

        if $COUNTRYOK; then
            log --color $COL_DEBUG "$LINE"
            run_query_and_handle_match "$LINE" $(echo "$LINE" | cut -d, -f 1)
        fi
    done < $SERVER_LIST

    local RESULT
    for RESULT in ${ANSWER_BASE}.match.*; do
        echo "$RESULT diff:"
        diff ${ANSWER_BASE}.model.0 $(echo $RESULT | perl -p -e 's/match/model/') | indent
        echo "$RESULT servers:" 
        cat $RESULT | indent
        echo "$RESULT by country:"
        cat $RESULT | perl -p -e 's/.*\///' | sort | uniq -c
        cat $RESULT | perl -p -e 's/.*\///' | sort | uniq -c | awk '{print $1}' | asciigraph -h 10
        echo
    done

    echo
    echo -n "    Delete state files? (y/n) "
    read -r LINE
    if [ "$LINE" = 'y' ]; then
        rm -f $SERVER_LIST ${ANSWER_BASE}*
    else
        echo "Leaving $SERVER_LIST and ${ANSWER_BASE}*"
    fi
}

function indent(){
    perl -p -e 's/^(.?)/    $1/'
}

read -r -d "" HELPTEXT << EOF
    TODO
EOF

options=$(getopt -o d:,c:,h -l domain:,country:,help -- "$@")

if [ $? -ne 0 ]; then
    echo "$HELPTEXT" | more
    exit 1
fi

eval set -- "$options"
while true; do
    case "$1" in
        -c | --country)
            shift
            FILTER_COUNTRY=$1
            ;;
        -d | --domain)
            shift
            DOMAIN=$1
            ;;
        -h | --help)
            echo "$HELPTEXT" | more
            exit 0
            ;;
        --)
            shift
            break
            ;;
    esac
    shift
done

if [ -z "$DOMAIN" ]; then
    log --color $COL_ERR "Error: --domain must be specified"
    exit 2
fi

main

