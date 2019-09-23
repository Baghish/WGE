export W2I_STRING=WGE-Information
export W2W_STRING=WGE-Warning
export W2E_STRING=WGE-Error
export WGE_DEBUG_DEFINITION="perl -d"

# Don't forget to set this symbol before you call this script
if [[ "$WGE_CONFIGURE_DB" ]] ; then
        printf "$W2I_STRING: Database set to $WGE_CONFIGURE_DB\n";
    else
	printf "$W2E_STRING: Set WGE_CONFIGURE_DB to the database profile for WGE\n";
	return
fi

if [[ ! "$WGE_SHARED" ]] ; then
	printf "$W2E_STRING: Set WGE_SHARED to the root directory of git checkouts\n";
	return
fi

if [[ ! "$WGE_CONFIGURE_OTS_URL" ]] ; then
    printf "$W2I_STRING: WGE_CONFIGURE_OTS_URL not set - WGE won't find the off target server!\n"
    return
fi

unset PERL5LIB

function wge {
    case $1 in
        live)
            wge_live
            ;;
        dev)
            wge_dev
            ;;
        show)
            wge_show
            ;;
        webapp)
            wge_webapp
            ;;
        debug)
            wge_webapp_debug
            ;;
        local)
            wge_local
            ;;
	production)
	    wge_production
	        ;;
        farm3)
            wge_farm3
            ;;
        'pg9.3')
            wge_pg9.3
            ;;
        psql)
            wge_psql
            ;;
        cpanm)
            wge_cpanm $2
            ;;
        force)
            wge_force $2
            ;;
        fcgi)
            wge_fcgi $2
            ;;
        apache)
            wge_apache $2
            ;;
        service)
            wge_service $2
            ;;
        setdb)
            wge_setdb $2 
            ;;
        *)
            printf "Unknown WGE command\n"
            wge_usage
    esac
}

function wge_usage {

    cat << END_USAGE
Usage: wge [command] [option [ ... ]]

commands:
    live:   use the live database defined in dbconnect
    dev:    use the dev database defined in dbconnect
    show:   list useful variables nicely formatted
    webapp: start the wge webapp on the default port
    debug:  start the webapp in perl debugging module
    local:  set up a local WGE environment
    farm3:  set up to run off-target scripts on farm3
    cpanm:  install a Perl module and document it
    force:  force install (only last resort)
    pg9.3:  use the Pg9.3 clients
    fcgi:   start start|stop the fcgi service
    apache: start|stop|reload the apache2 service
    service: start|stop the fcgi and apaches2 services
    production: set things up for production mode logging (to file)
    dev:    set things up for development logging (to terminal) 

END_USAGE
}

function _wge_completions {
    COMPREPLY=()
    local curr=${COMP_WORDS[COMP_CWORD]}
    if [[ $COMP_CWORD -eq 1 ]]; then
        COMPREPLY=($(compgen -W "help show webapp debug setdb local test replicate devel wge pg9.3 psql audit regenerate_schema cpanm fcgi apache service production dev" -- "$curr"))
    elif [[ $COMP_CWORD -eq 2 ]]; then
        case ${COMP_WORDS[1]} in
            setdb)
                local dbs=($($WGE_DEV_ROOT/bin/list_db_names.pl --list))
                local ILS=" "
                local options="${dbs[@]}"
                COMPREPLY=($(compgen -W "$options" -- "$curr"))
                ;;
            replicate)
                COMPREPLY=($(compgen -W "test local staging" -- "$curr"))
                ;;
            wge)
                COMPREPLY=($(compgen -W "live devel" -- "$curr"))
                ;;
            *)
                ;;
        esac
    fi
} &&
complete -F _wge_completions wge

function perlmodpath ()
{
    test -n "$1" || {
	echo 'Usage: perlmodpath MODULE' 1>&2;
	return
    };
    perl -m"$1" -le '$ARGV[0]=~s/::/\//g; print $INC{"$ARGV[0].pm"}' "$1"
}

function wge_webapp {
    if [[  "$1"   ]] ; then
        WGE_PORT=$1 
    elif [[ "$WGE_WEBAPP_SERVER_PORT"  ]] ; then
        WGE_PORT=$WGE_WEBAPP_SERVER_PORT
    else
        WGE_PORT=3000
    fi
    printf "starting WGE webapp on port $WGE_PORT";
    if [[ "$WGE_WEBAPP_SERVER_OPTIONS" ]] ; then
        printf " with options $WGE_WEBAPP_SERVER_OPTIONS";
    fi
    printf "\n\n"
    printf "$W2I_STRING: $WGE_DEBUG_COMMAND $WGE_DEV_ROOT/script/wge_server.pl -p $WGE_PORT $WGE_WEBAPP_SERVER_OPTIONS\n"
    $WGE_DEBUG_COMMAND $WGE_DEV_ROOT/script/wge_server.pl -p $WGE_PORT $WGE_WEBAPP_SERVER_OPTIONS
}

function wge_webapp_debug {
    WGE_DEBUG_COMMAND=$WGE_DEBUG_DEFINITION
    wge_webapp $1
    unset WGE_DEBUG_COMMAND
}

function wge_setdb {
    if [[ "$1" ]] ; then
        if [[ `$WGE_DEV_ROOT/bin/list_db_names.pl $1` == $1 ]] ; then
        export WGE_DB=$1
        printf "$W2I_STRING: database is now $WGE_DB\n"
        else
            printf "$W2E_STRING: database '$1' does not exist in $WGE_DBCONNECT_CONFIG\n"
        fi
    else
        # List the databases available
        printf "$W2I_STRING: Available database names from WGE_DBCONNECT_CONFIG\n\n"
        $WGE_DEV_ROOT/bin/list_db_names.pl
        printf "Use 'wge psql' command to open a psql command line for this db\n"
    fi
}



function wge_live {
    export WGE_DB=WGE_LIVE
}

function wge_dev {
    export WGE_DB=WGE_BUILD_DB
}

function check_and_set {
    if [[ ! -f $2 ]] ; then
        printf "$W2W_STRING: $2 does not exist but you are setting $1 to its location\n"
    fi
    export $1=$2
}

function check_and_set_dir {
    if [[ ! -d $2 ]] ; then
        printf "$W2W_STRING: directory $2 does not exist but you are setting $1 to its location\n"
    fi
    export $1=$2
}

function wge_cpanm {
    if [[ "$1" ]] ; then
        cpanm -l $WGE_OPT/perl5 $1
        echo $1 >> $WGE_OPT/perl_depend.log
    else
        printf "$W2E_STRING: no module specified: wge_cpanm <module>\n"
    fi
}

function wge_force {
    if [[ "$1" ]] ; then
        cpanm -l $WGE_OPT/perl5 --force $1
        echo $1 >> $WGE_OPT/perl_depend.log
    else
        printf "$W2E_STRING: no module specified: wge_cpanm <module>\n"
    fi
}

function wge_pg9.3 {
    check_and_set PSQL_EXE $WGE_OPT/postgres/9.3.4/bin/psql
    check_and_set PG_DUMP_EXE $WGE_OPT/postgres/9.3.4/bin/pg_dump
    check_and_set PG_RESTORE_EXE $WGE_OPT/postgres/9.3.4/bin/pg_restore
}

function wge_psql {
    export WGE_DB_NAME=`$WGE_DEV_ROOT/bin/list_db_names.pl $WGE_DB --dbname`
    printf "Opening psql shell with database: $WGE_DB_NAME (profile: $WGE_DB)\n"
    $PSQL_EXE `$WGE_DEV_ROOT/bin/list_db_names.pl $WGE_DB --uri`
}


function wge_pg_dump {
    $PG_DUMP_EXE
}

function wge_pg_restore {
    $PG_RESTORE_EXE
}

function perl5lib_prepend ()
{
    test -n "$1" || {
        warn "COMPONENT not specified";
        return 1
    };
    export PERL5LIB=$(perl -le "print join ':', '$1', grep { length and \$_ ne '$1' } split ':', \$ENV{PERL5LIB}")
}

function wge_fcgi ()
{
    if [[ "$1" ]] ; then
        $WGE_DEV_ROOT/bin/fcgi-manager.pl --config "${WGE_FCGI_CONFIG}" "$1" wge
    else
        printf "$W2E: must supply start|stop|restart to wge fcgi command\n"
    fi
}

function wge_apache {
    if [[ "$1" ]] ; then
        /usr/sbin/apachectl -f $WGE_OPT/conf/wge/apache.conf -k $1
    else
        printf "$W2E: must supply start|stop|restart to wge apache command\n"
    fi
}

function wge_service {
    if [[ "$1" ]] ; then
        wge_fcgi $1
        wge_apache $1
    else
        printf "$W2E: must supply start|stop|restart to wge service command\n"
    fi
}

function wge_show {
cat << END
WGE useful environment variables:

\$WGE_DEV_ROOT:                 : $WGE_DEV_ROOT
\$WGE_SHARED                    : $WGE_SHARED
\$SAVED_WGE_DEV_ROOT            : $SAVED_WGE_DEV_ROOT 
\$WGE_WEBAPP_SERVER_PORT        : $WGE_WEBAPP_SERVER_PORT
\$WGE_WEBAPP_SERVER_OPTIONS     : $WGE_WEBAPP_SERVER_OPTIONS
\$WGE_DEBUG_DEFINITION          : $WGE_DEBUG_DEFINITION
\$WGE_OPT                       : $WGE_OPT

PERL5LIB :
`perl -e 'print( join("\n", split(":", $ENV{PERL5LIB}))."\n")'`

\$PATH :
`perl -e 'print( join("\n", split(":", $ENV{PATH}))."\n")'`

\$WGE_REST_CLIENT_CONFIG            : $WGE_REST_CLIENT_CONFIG
\$WGE_FCGI_CONFIG                   : $WGE_FCGI_CONFIG
\$WGE_NO_TIMEOUT                    : $WGE_NO_TIMEOUT
\$WGE_DBCONNECT_CONFIG              : $WGE_DBCONNECT_CONFIG
\$WGE_SESSION_STORE                 : $WGE_SESSION_STORE
\$WGE_OAUTH_CLIENT                  : $WGE_OAUTH_CLIENT
\$WGE_GMAIL_CONFIG                  : $WGE_GMAIL_CONFIG
\$WGE_LOG4PERL_CONFIG               : $WGE_LOG4PERL_CONFIG
\$LIMS2_REST_CLIENT_CONFIG          : $LIMS2_REST_CLIENT_CONFIG
\$OFF_TARGET_SERVER_URL             : $OFF_TARGET_SERVER_URL
\$WGE_ENSEMBL_HOST                  : $WGE_ENSEMBL_HOST
\$WGE_ENSEMBL_USER                  : $WGE_ENSEMBL_USER
\$WGE_DB                            : $WGE_DB


END
wge_local_environment
}

function wge_ensembl_modules {
    export PATH=$WGE_SHARED/ensembl-git-tools/bin:$PATH
    perl5lib_prepend $WGE_SHARED/ensembl-variation/modules
    perl5lib_prepend $WGE_SHARED/ensembl/modules
    perl5lib_prepend $WGE_SHARED/ensembl-compara/module
    export LIMS2_ENSEMBL_HOST=$WGE_ENSEMBL_HOST
    export LIMS2_ENSEMBL_USER=$WGE_ENSEMBL_USER
}

function wge_lib {
    perl5lib_prepend $WGE_DEV_ROOT/lib  
}

function lims2_lib {
    perl5lib_prepend $LIMS2_DEV_ROOT/lib
}

function wge_farm3 {
    wge_local
    unset PERL5LIB

    wge_ensembl_modules
   
    perl5lib_prepend /nfs/team87/farm3_lims2_vms/software/perl/lib/perl5    
}

function wge_local {
    wge_opt
    export PERL_CPANM_OPT="--local-lib=$WGE_OPT/perl5"
    perl5lib_prepend $WGE_SHARED/LIMS2-REST-Client/lib
    perl5lib_prepend $WGE_SHARED/Design-Creation/lib
    perl5lib_prepend $WGE_SHARED/LIMS2-Exception/lib
    perl5lib_prepend $WGE_SHARED/WebApp-Common/lib
    perl5lib_prepend $WGE_OPT/perl5/lib/perl5
    check_and_set LIMS2_REST_CLIENT_CONFIG $WGE_OPT/conf/wge/wge-rest-client.conf
    check_and_set WGE_REST_CLIENT_CONFIG $WGE_OPT/conf/wge/wge-rest-client.conf
    check_and_set WGE_DBCONNECT_CONFIG $WGE_OPT/conf/wge/wge_dbconnect.yml
    export OFF_TARGET_SERVER_URL=$WGE_CONFIGURE_OTS_URL
    check_and_set WGE_FCGI_CONFIG $WGE_CONFIGURE_FCGI
    export WGE_DB=$WGE_CONFIGURE_DB
    export WGE_SESSION_STORE=/tmp/wge-devel.session.$USER
    unset LIMS2_DB
    check_and_set WGE_OAUTH_CLIENT $WGE_OPT/conf/wge/oauth.json
    check_and_set WGE_GMAIL_CONFIG $WGE_OPT/conf/wge/wge_gmail_account.yml
    check_and_set WGE_LOG4PERL_CONFIG $WGE_OPT/conf/wge/wge.log4perl.default.conf
    check_and_set_dir SHARED_WEBAPP_STATIC_DIR $WGE_SHARED/WebApp-Common/shared_static
    check_and_set_dir SHARED_WEBAPP_TT_DIR $WGE_SHARED/WebApp-Common/shared_templates

    wge_ensembl_modules

    lims2_lib

    wge_lib
}

function wge_opt {
# Location of optional software to support admin of WGE
    if [[ ! $WGE_OPT ]] ; then
        printf "$W2I_STRING: WGE_OPT set to: $WGE_OPT\n"
    	export WGE_OPT=~/opt
    fi
}
function wge_production {
    check_and_set WGE_LOG4PERL_CONFIG $WGE_OPT/conf/wge/wge.log4perl.production.conf 
    check_and_set WGE_PRODUCTION_ROOT $WGE_CONFIGURE_PRODUCTION_ROOT
    check_and_set WGE_APACHE_PORT $WGE_CONFIGURE_APACHE_PORT
    check_and_set WGE_SERVER_EMAIL $WGE_CONFIGURE_SERVER_EMAIL
}

function wge_local_environment {
    printf "No local WGE environment defined\n"
}

if [[ -f $HOME/.wge_local ]] ; then
    printf "Sourcing local mods to wge environment\n"
    source $HOME/.wge_local
fi

wge_local