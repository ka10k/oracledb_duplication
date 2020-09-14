#!/bin/bash

# author a.grishin                     
# SBT_TAPE SIP database duplication script v1.1
# ensure that backup has passed and scheduler disabled

function set_parameters() {
    PROD_HOST=sip-nn.mrk.vt.ru
    PROD_SID=SIP
    PROD_PORT=1521
    PROD_SYS_PSWD=qwaszx12
    TEST_HOST=sip-tst.mrk.vt.ru
    TEST_SID=TSIPNN
    TEST_PORT=1540
    TEST_SYS_PSWD=qwaszx12
    UNDO_TBS='UNDOTBS1'
    ASM_DG=SIPTST
    RECOVERY_DEST_SIZE=500G
    SGA=4G
    PGA=2G
    ENV_DB=.envTSIPNN
    ENV_CRS=.envCRS
    DB_VER=11
    RECOVER_UNTIL='06/04/2020 07:00:00'
    DROP_ASM_STORAGE=1
    DROP_DB_LINKS=1
    DELETE_DB_LINKS=1
    JOBS_BROKEN=0
}

function load_env() {
    . ~/$1
}

function create_init_file() {
    load_env $ENV_DB
    local init_file=$ORACLE_HOME/dbs/init$1.ora
    local aud_dest='/ora/admin/'$1'/adump'
    
    if [ ! -d $aud_dest ]; then
        mkdir -p $aud_dest
    fi

    if [ -f $init_file ]; then
        mv $init_file $init_file.old
    fi

    cat << EOF >> $ORACLE_HOME/dbs/init$1.ora
    $1.__db_cache_size=2818572288
    $1.__java_pool_size=50331648
    $1.__large_pool_size=67108864
    $1.__oracle_base='/ora','/ora'#ORACLE_BASE set from environment
    $1.__pga_aggregate_target=2147483648
    $1.__sga_target=4294967296
    $1.__shared_io_pool_size=0
    $1.__shared_pool_size=1308622848
    $1.__streams_pool_size=0
    *._dbms_sql_security_level=384
    *.audit_file_dest='$aud_dest'
    *.audit_trail='NONE'
    *.compatible='11.2.0.4.0'
    *.control_files='+$2/$1/control01.ctl','+$2/$1/control02.ctl'#Restore Controlfile
    *.db_block_size=$6
    *.db_create_file_dest='+$2'
    *.db_domain=''
    *.db_name='$1'
    *.db_recovery_file_dest='+$2'
    *.db_recovery_file_dest_size=500G
    *.db_create_file_dest='+$2'
    *.db_files=1000
    *.diagnostic_dest='/ora'
    *.dispatchers=''
    *.job_queue_processes=0
    *.aq_tm_processes=0
    *.max_shared_servers=0
    *.open_cursors=300
    *.processes=1500
    *.remote_login_passwordfile='EXCLUSIVE'
    *.sessions=1655
    *.sga_max_size=$3
    *.sga_target=$3
    *.pga_aggregate_target=$4
    *.shared_servers=0
    *.undo_retention=28800
    *.undo_tablespace='$5'
EOF
}

create_sp_file() {
    load_env $ENV_DB
    lower_sid=$(echo $2 | tr '[:upper:]' '[:lower:]')
    echo "create spfile='+$1/$2/spfile$lower_sid.ora' from pfile;" | sqlplus -s sys/$3@$4:$5/$2 as sysdba
    local init_file=$ORACLE_HOME/dbs/init$2.ora
    echo "SPFILE='+$1/$2/spfile$lower_sid.ora'" > $init_file
    if [ -f "$ORACLE_HOME/dbs/spfile$2.ora" ]; then
        mv -f $ORACLE_HOME/dbs/spfile$2.ora $ORACLE_HOME/dbs/spfile$2.ora.old
    fi
}

function create_pw_file() {
    load_env $ENV_DB
    local pw_file=$(echo $ORACLE_HOME/dbs/orapw$ORACLE_SID)
    if [ -f $pw_file ]; then
        return 0
    else
        if [[ DB_VER -gt 11 ]]; then
            orapwd file=$pw_file password=$1 entries=5 format=12 force=y
        else
            orapwd file=$pw_file password=$1 entries=5 force=y
        fi
    fi
}

function listener_exists() {
    lsnr_exists=$(grep -Ec 'SID_NAME.*'$TEST_SID'' \
    $ORACLE_HOME/network/admin/listener.ora)
    echo $lsnr_exists
}

function get_listener_name() {
    local lsnr_name=LISTENER_$(grep -E 'SID_NAME.*'$TEST_SID'' \
    $ORACLE_HOME/network/admin/listener.ora -B 5 | \
    grep SID_LIST_LISTENER | cut -d '_' -f4 | sed 's/\s.*//')
    echo $lsnr_name
}

function get_listener_host() {
    local lsnr_host=$(grep -A3 ^$(get_listener_name) \
    $ORACLE_HOME/network/admin/listener.ora | \
    grep HOST | sed 's/^.*HOST = //;s/)(.*//')
    echo $lsnr_host
}

function get_listener_port() {
    local lsnr_port=$(grep -A3 ^$(get_listener_name) \
    $ORACLE_HOME/network/admin/listener.ora | \
    grep PORT | sed 's/^.*PORT = //;s/))//')
    echo $lsnr_port
}

function port_is_occupied() {
    local occupied=$(netstat -nltp 2>/dev/null | grep -c $(get_listener_port))
    echo $occupied
}

function listener_is_running() {
    local listener_is_running=$(ps -ef | grep tnslsnr | grep -c $(get_listener_name))
    echo $listener_is_running
}

function create_listener() {
    cat << EOF >> $ORACLE_HOME/network/admin/listener.ora
SID_LIST_LISTENER_$1 =
    (SID_LIST =
        (SID_DESC =
        (GLOBAL_DBNAME = $1)
        (ORACLE_HOME = $ORACLE_HOME)
        (SID_NAME = $1)
        )
    )

LISTENER_$1 =
    (DESCRIPTION =
    (ADDRESS = (PROTOCOL = TCP)(HOST = $2)(PORT = $3))
    )
EOF
}

function shutdown_db() {
     load_env $ENV_DB
     sqlplus -s / as sysdba << EOF
     shutdown immediate
     EXIT; 
EOF
     sleep 30
}

function start_db() {
     load_env $ENV_DB
     sqlplus -s / as sysdba << EOF
     startup $1
     EXIT;
EOF
     sleep 30
}

function drop_db() {
    load_env $ENV_CRS
    asmcmd << EOF
    cd $1
    rm -rf $2
    mkdir $2
    cd $2
    mkdir FRA
    mkdir DB
    exit 
EOF
}

function get_instance_status() {
    load_env $ENV_DB
    local status=$(echo "select STATUS from v\$instance;" | sqlplus -s / as sysdba | grep -A 2 STATUS | tail -n 1)
    echo $status
}

function get_db_state() {
    load_env $ENV_DB
    instance_status=$(echo "select status from v\$instance;" | sqlplus -s / as sysdba)
    db_mode=$(echo "select open_mode from v\$database;" | sqlplus -s / as sysdba)

    if [[ $(echo $instance_status | grep -c 'ORACLE not available') -eq 1 ]]; then
        db_status='SHUT'
    fi

    if [[ $(echo $db_mode | grep -c 'database not mounted') -eq 1 ]]; then
        db_status='NOMOUNT'
    fi

    if [[ $(echo $db_mode | grep -c 'MOUNTED') -eq 1 ]]; then
        db_status='MOUNT'
    fi

    if [[ $(echo $instance_status | grep -c 'OPEN') -eq 1 ]]; then
        db_status='OPEN'
    fi

    echo $db_status
}

function check_connection() {
    load_env $ENV_DB
    local result=$(tnsping $1:$2 | tail -n 1 | sed 's/\(^..\)\(.*$\)/\1/g')
    echo $result
}

function check_asm_free_space() {
    load_env $ENV_CRS
    local asm_free_mb=$(asmcmd lsdg $1 | awk '{ print $8 }' | tail -n 1)
    echo $asm_free_mb
}

function check_prod_dbsize() {
    load_env $ENV_DB
    local prod_dbsize=$(echo "\
    select round( \
    ( select sum(bytes)/1024/1024 data_file_size from dba_data_files ) + \
    ( select nvl(sum(bytes),0)/1024/1024 temp_file_size from dba_temp_files ) + \
    ( select sum(bytes)/1024/1024 redo_file_size from sys.v_\$log ) + \
    ( select sum(BLOCK_SIZE*FILE_SIZE_BLKS)/1024/1024 controlfile_size from v\$controlfile)) \"Total Size in mb\" \
    from dual;" | sqlplus -s sys/$1@$2:$3/$4 as sysdba | grep -A2 'Total Size' | tail -n 1)
    echo $prod_dbsize
}

function get_undo_name() {
    load_env $ENV_DB
    UNDO=$(echo -e "SET HEADING OFF FEEDBACK OFF HEAD OFF PAGES 0;\n \
    select VALUE from V\$PARAMETER where NAME = 'undo_tablespace';" | \
    sqlplus -s sys/$1@$2:$3/$4 as sysdba)
    echo $UNDO
}

function get_db_block_size() {
    local block_size=$(echo -e "SET HEADING OFF FEEDBACK OFF HEAD OFF PAGES 0;\n \
    select VALUE from V\$PARAMETER where NAME = 'db_block_size';" | \
    sqlplus -s sys/$1@$2:$3/$4 as sysdba)
    echo $block_size
}

function get_db_files() {
    local db_files=$(echo -e "SET HEADING OFF FEEDBACK OFF HEAD OFF PAGES 0;\n \
    select VALUE from V\$PARAMETER where NAME = 'db_files';" | \
    sqlplus -s sys/$1@$2:$3/$4 as sysdba) 
    echo $db_files
}

function set_spfile_additional_parameters() {
    load_env $ENV_DB
    sqlplus -s / as sysdba << EOF
    startup nomount
    alter system set db_create_file_dest ='+$1' scope=spfile;
    alter system set db_recovery_file_dest='+$1' scope=spfile;
    alter system reset db_file_name_convert scope=spfile;
    alter system reset log_file_name_convert scope=spfile;
    alter system set db_recovery_file_dest_size=$2;
    alter system set db_files=$3 scope=spfile;
    alter system set aq_tm_processes=0;
    alter system set job_queue_processes=0;
    alter system set compatible='11.2.0.4.0' scope=spfile;
    --alter system set compatible='19.0.0' scope=spfile;
    shutdown immediate
    startup nomount
    EXIT;
EOF
}

function duplicate_db() {
    load_env $ENV_DB
    rman target sys/$1@$2:$3/$4 catalog rman112/rman@rcat auxiliary sys/$5@$6:$7/$8 << EOF
    run {
    set until time "TO_DATE('$9','DD/MM/YYYY HH24:MI:SS')";
    allocate channel ch0 type disk;
    allocate channel ch1 type disk;
    allocate channel ch2 type disk;
    allocate channel ch3 type disk;
    allocate channel ch4 type disk;
    allocate channel ch5 type disk;
    allocate channel ch6 type disk;
    allocate channel ch7 type disk;
    allocate channel ch8 type disk;
    allocate auxiliary channel ch100 type SBT_TAPE PARMS="SBT_LIBRARY=/opt/omni/lib/libob2oracle8_64bit.so ENV=(OB2BARTYPE=Oracle8,OB2BARHOSTNAME=$(hostname))";
    allocate auxiliary channel ch101 type SBT_TAPE PARMS="SBT_LIBRARY=/opt/omni/lib/libob2oracle8_64bit.so ENV=(OB2BARTYPE=Oracle8,OB2BARHOSTNAME=$(hostname))";
    allocate auxiliary channel ch102 type SBT_TAPE PARMS="SBT_LIBRARY=/opt/omni/lib/libob2oracle8_64bit.so ENV=(OB2BARTYPE=Oracle8,OB2BARHOSTNAME=$(hostname))";
    allocate auxiliary channel ch103 type SBT_TAPE PARMS="SBT_LIBRARY=/opt/omni/lib/libob2oracle8_64bit.so ENV=(OB2BARTYPE=Oracle8,OB2BARHOSTNAME=$(hostname))";
    allocate auxiliary channel ch104 type SBT_TAPE PARMS="SBT_LIBRARY=/opt/omni/lib/libob2oracle8_64bit.so ENV=(OB2BARTYPE=Oracle8,OB2BARHOSTNAME=$(hostname))";
    allocate auxiliary channel ch105 type SBT_TAPE PARMS="SBT_LIBRARY=/opt/omni/lib/libob2oracle8_64bit.so ENV=(OB2BARTYPE=Oracle8,OB2BARHOSTNAME=$(hostname))";
    allocate auxiliary channel ch106 type SBT_TAPE PARMS="SBT_LIBRARY=/opt/omni/lib/libob2oracle8_64bit.so ENV=(OB2BARTYPE=Oracle8,OB2BARHOSTNAME=$(hostname))";
    allocate auxiliary channel ch107 type SBT_TAPE PARMS="SBT_LIBRARY=/opt/omni/lib/libob2oracle8_64bit.so ENV=(OB2BARTYPE=Oracle8,OB2BARHOSTNAME=$(hostname))";
    allocate auxiliary channel ch108 type SBT_TAPE PARMS="SBT_LIBRARY=/opt/omni/lib/libob2oracle8_64bit.so ENV=(OB2BARTYPE=Oracle8,OB2BARHOSTNAME=$(hostname))";
    duplicate target database to $8 nofilenamecheck;
    }
    EXIT;
EOF
sleep 30   
}

#- During the datafile restore (after CF restore) , connect to DB (in mount state).
#- Execute : alter database disable block change tracking;
#- SQL> ALTER DATABASE DISABLE BLOCK CHANGE TRACKING;
function disable_bct() {
    load_env $ENV_DB
    sleep 1h
    if [ $(get_instance_status) != "MOUNTED" ]; then
        echo 'BLOCK CHANGE TRACKING IS NOT DISABLED'
        return 1    
    fi
    sqlplus / as sysdba << EOF
    ALTER DATABASE DISABLE BLOCK CHANGE TRACKING;
    EXIT;
EOF
}

function noarchivelog() {
    load_env $ENV_DB
    sqlplus / as sysdba << EOF
    SHUTDOWN IMMEDIATE
    STARTUP MOUNT
    ALTER DATABASE NOARCHIVELOG;
    ALTER DATABASE OPEN;
    grant drop public database link to SIP_W;
    grant create public database link to SIP_W;
    grant create database link to SIP_W;
    EXIT;
EOF
}

function delete_dblinks() {
    load_env $ENV_DB
    sqlplus / as sysdba << EOF
    delete from sys.link$;
    commit;
    exit;
EOF
}

function drop_dblinks() {
    load_env $ENV_DB
    sqlplus / as sysdba << EOF
    set serveroutput on;
    declare
    sql_stmt  VARCHAR2(200);

    BEGIN
    for i in
    (select owner, db_link from dba_db_links)
    loop
        begin
        if i.owner = 'PUBLIC' then
            sql_stmt := q'[DROP PUBLIC DATABASE LINK "]' || i.db_link || q'["]';
            dbms_output.put_line(sql_stmt);
            execute immediate sql_stmt;
        else
            sql_stmt := q'[CREATE OR REPLACE PROCEDURE ]' || i.owner || '.drop_db_link AS BEGIN ' ||  
                        q'[EXECUTE IMMEDIATE 'drop database link ]' || i.db_link || q'[';]' ||
                        q'[END drop_db_link;]';
            dbms_output.put_line(sql_stmt);   
            execute immediate sql_stmt;
            sql_stmt := 'BEGIN ' || i.owner || '.drop_db_link; END;';
            dbms_output.put_line(sql_stmt);
            execute immediate sql_stmt;
        end if;
         EXCEPTION
            WHEN OTHERS THEN
                DBMS_OUTPUT.PUT_LINE (SQLERRM || ', SQLCODE='|| SQLCODE);    
                CONTINUE;
         end;        
    end loop;

    END;
    /
    EXIT;
EOF
}

function set_jobs_broken() {
    load_env $ENV_DB
    sqlplus / as sysdba << EOF
    set serveroutput on;
    set serveroutput on size 1000000
    exec DBMS_OUTPUT.ENABLE(1000000);
    declare
    sql_stmt  VARCHAR2(200);
    BEGIN
    for i in (
    select schema_user,job from dba_jobs 
        where 1=1 
        and broken='N') 
        loop
            begin
            sql_stmt := 'alter session set current_schema=' || i.schema_user;
            DBMS_OUTPUT.PUT_LINE(sql_stmt);
            execute immediate sql_stmt;
            sys.dbms_ijob.broken(i.job ,TRUE);
            EXCEPTION WHEN OTHERS THEN DBMS_OUTPUT.PUT_LINE (SQLERRM || ', SQLCODE='|| SQLCODE);
            end;
        end loop;
    END;    
    /
    EXIT;
EOF
}

function disable_scheduler_jobs() {
    load_env $ENV_DB
    sqlplus / as sysdba << EOF
    begin
        sys.dbms_scheduler.disable('SYS.DROP_ARCH_DATA');
        sys.dbms_scheduler.disable('SYS.MIGRATION_TO_SIPARCH');
    end;
    / 
    EXIT;
EOF
}

function main() {
    set_parameters
    load_env $ENV_DB

    if [[ $(listener_exists $TEST_SID) -eq 0 ]]; then
        echo 'Creating listener'
        echo 'Starting listener'
        create_listener $TEST_SID $TEST_HOST $TEST_PORT
        lsnrctl start $(get_listener_name)
    else
        if [[ $(port_is_occupied $(get_listener_port)) -eq 1 ]]; then
            echo 'Port '$(get_listener_port)' is occupied'
            if [[ $(listener_is_running) -eq 1 ]]; then
                echo 'Listener '$(get_listener_name)' is already running'                
            fi
        else
            echo 'Listener is not running. Starting listener.'
            lsnrctl start $(get_listener_name)
        fi
    fi

    if [[ $(port_is_occupied $(get_listener_port)) -eq 0 ]] || [[ $(listener_is_running) -eq 0 ]]; then
        echo 'Something goes wrong. Please check listener configuration manually.'
        exit 1
    fi

    if [ ! -f ~/$ENV_DB ] || [ ! -f ~/$ENV_CRS ]; then
        echo $'Environment file doesn\'t exist' 
        exit 1
    fi

    if [ "$(check_connection $PROD_HOST $PROD_PORT)" != "OK" ]; then
        echo 'Connection problem '$PROD_HOST':'$PROD_PORT''
        exit 1
    fi
    
    if [ "$(check_connection $TEST_HOST $TEST_PORT)" != "OK" ]; then
        echo 'Connection problem '$TEST_HOST':'$TEST_PORT''
        exit 1
    fi

    shutdown_db

    if [[ $DROP_ASM_STORAGE -eq 1 ]]; then
        load_env $ENV_CRS
        drop_db $ASM_DG $TEST_SID
    fi


    local asm_free_mb=$(check_asm_free_space $ASM_DG)
    local prod_dbsize_mb=$(check_prod_dbsize $PROD_SYS_PSWD $PROD_HOST $PROD_PORT $PROD_SID)
    local recovery_size_mb=$(($(echo $RECOVERY_DEST_SIZE | sed 's/G//')*1024))
    local space_needed=$(( $prod_dbsize_mb + $recovery_size_mb ))
    local db_block_size=$(get_db_block_size $PROD_SYS_PSWD $PROD_HOST $PROD_PORT $PROD_SID)
    local db_files=$(get_db_files $PROD_SYS_PSWD $PROD_HOST $PROD_PORT $PROD_SID)

    if [[ $space_needed -gt $asm_free_mb ]]; then
        echo 'Free space '$asm_free_mb' mb is not enough for duplication'
        echo 'Production DB size is '$prod_dbsize_mb' mb'
        echo 'Recovery dest size is '$recovery_size_mb' mb'
        exit 1
    fi
    
    UNDO_TBS=$(get_undo_name $PROD_SYS_PSWD $PROD_HOST $PROD_PORT $PROD_SID)

    create_init_file $TEST_SID $ASM_DG $SGA $PGA $UNDO_TBS $db_block_size
    create_sp_file $ASM_DG $TEST_SID $TEST_SYS_PSWD $TEST_HOST $TEST_PORT
    create_pw_file $TEST_SYS_PSWD
    set_spfile_additional_parameters $ASM_DG $RECOVERY_DEST_SIZE $db_files

    shutdown_db

    disable_bct &
    
    if [ $(get_db_state) != "NOMOUNT" ]; then
        start_db nomount
    fi

    duplicate_db $PROD_SYS_PSWD $PROD_HOST $PROD_PORT $PROD_SID $TEST_SYS_PSWD $TEST_HOST $TEST_PORT $TEST_SID $RECOVER_UNTIL

    if [ $(get_db_state) != "OPEN" ]; then
        echo 'Something goes wrong'
        exit 1
    fi

    noarchivelog
    
    if [[ $JOBS_BROKEN -eq 1 ]]; then
        set_jobs_broken
    fi

    if [[ $DROP_DB_LINKS -eq 1 ]]; then
        drop_dblinks
    fi

    if [[ $DELETE_DB_LINKS -eq 1 ]]; then
        delete_dblinks
    fi
    
}

main

