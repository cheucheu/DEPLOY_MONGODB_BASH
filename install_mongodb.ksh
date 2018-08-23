#!/bin/ksh93
#-----------------------------------------------------------------------------------------------------
# Copyright(c) 2018 Orange SA
#
# NAME
#    install_replicaset.ksh 
#
# DESCRIPTION
#
#    Deploying Orange Industrialization MongoDB RPM on several servers and configure a replicaset or a sharding cluster.
#    This script should be launched only one of servers and use a config file to descrive the configuration.
#
# REMARKS
#
#    - This shell script must be run by root with the  ksh93 to use useful associative arrays.  
#    - The openssh configuration must be enabled to execute  remote commands between servers.
#    - Be careful, you can't have multiple replicaset or sharded instances on the same server. 
#      However, in a shard configuration, a server could shared a config server, a shard server and a mongos instance.
# 
# Prerequisites :
#
#   -  The Linux Tree has to respect the Linux Common Bundle Standards.
#   -  The parameter <PermitRootLogin> must be valued at YES in the file /etc/ssh/sshd_config
#      After modify,restart the deamon: systemctl restart sshd
#
# Input Parameters :
#
#   -  The config file to describe the overall configuration.
#      To define a sharding cluster, we must specify all below sections. Here's an example :
#
#        ###################
#        #replicaset config#
#        ###################
#        replicaset=RS0:dvxx2asc8m:27017
#        replicaset=RS0:dvxx2asc8n:27018
#        replicaset=RS0:dvxx2asc8p:27019
#        replicaset=RS1:dvxx2asc8q:27017
#        ###########################
#        #config servers sharding  #
#        ###########################
#        config=dvxx2asc8m:27020
#        config=dvxx2asc8n:27021
#        config=dvxx2asc8p:27022
#        #################
#        #mongos sharding#
#        #################
#        mongos=dvxx2asc8m:27014
#        ##########
#        #sharding#
#        ##########
#        shard=SH1:dvxx2asc8m
#        shard=SH2:dvxx2asc8q
#       
#   To define a replicaset, just keep the section "replicaset config".
#
#  Output :
#
#       stdout
#       Log file : current_directory/install_replicaset.log
#-----------------------------------------------------------------------------------------------------
# CHANGE LOGS
#    HERVE AGASSE (Orange/OF/DESI/DIXSI/PTAL) - 2018/02/20- v1.0.0 - Creation
#    HERVE AGASSE (Orange/OF/DESI/DIXSI/PTAL) - 2018/02/20- v1.0.1 - Correction bugs and logging
#------------------------------------------------------------------------------------------------------
#  
#------------------------------------------
# text colors
#-----------------------------------------
export red=`tput setaf 1`
export green=`tput setaf 2`
export reset=`tput sgr0`

#------------------------------------------
# Functions
#-------------------------------------------
# Trapping interrupts
#-------------------------------------------
trap 'echo ^C received breaking... ;F_End 1' INT 
trap 'echo Killed;F_End 1' KILL 
trap 'echo ^Z not allowed breaking;F_End 1' TSTP SIGTSTP

#-------------------------------------------
# Regular exit function
#-------------------------------------------
F_End()
{
[ -t 3 ] && exec 2>&3 1>&2 3>&- # back to standard output
ReturnCode=$1

[ "${ReturnCode}" = 0 ] && ReturnMsg="OK" || ReturnMsg="Unexpected"
if [ -f ${LogFile} ] && [ ! "${LogFile}" == "" ]
then
echo "\n\t@ ReturnCode=${ReturnCode} ( ${ReturnMsg} )" >>  ${LogFile}
# Don't change following grep command
cat ${LogFile} | grep "^	@ " 2>&1
fi
exit ${ReturnCode}
}

Mon_colorShell()
{
    # Escape sequence and resets
    ESC_SEQ="\x1b["
    RESET_ALL="${ESC_SEQ}0m"
    RESET_BOLD="${ESC_SEQ}21m"
    RESET_UL="${ESC_SEQ}24m"
    export ESC_SEQ RESET_ALL RESET_BOLD RESET_UL

    # Foreground colours
    FG_BLACK="${ESC_SEQ}30;"
    FG_RED="${ESC_SEQ}31;"
    FG_GREEN="${ESC_SEQ}32;"
    FG_YELLOW="${ESC_SEQ}33;"
    FG_BLUE="${ESC_SEQ}34;"
    FG_MAGENTA="${ESC_SEQ}35;"
    FG_CYAN="${ESC_SEQ}36;"
    FG_WHITE="${ESC_SEQ}37;"
    FG_BR_BLACK="${ESC_SEQ}90;"
    FG_BR_RED="${ESC_SEQ}91;"
    FG_BR_GREEN="${ESC_SEQ}92;"
    FG_BR_YELLOW="${ESC_SEQ}93;"
    FG_BR_BLUE="${ESC_SEQ}94;"
    FG_BR_MAGENTA="${ESC_SEQ}95;"
    FG_BR_CYAN="${ESC_SEQ}96;"
    FG_BR_WHITE="${ESC_SEQ}97;"
    export FG_BLACK FG_RED FG_GREEN FG_YELLOW FG_BLUE FG_MAGENTA FG_CYAN FG_WHITE
    export FG_BR_BLACK FG_BR_RED FG_BR_GREEN FG_BR_YELLOW FG_BR_BLUE FG_BR_MAGENTA FG_BR_CYAN FG_BR_WHITE
    
# Background colours (optional)
    BG_BLACK="40;"
    BG_RED="41;"
    BG_GREEN="42;"
    BG_YELLOW="43;"
    BG_BLUE="44;"
    BG_MAGENTA="45;"
    BG_CYAN="46;"
    BG_WHITE="47;"
    export BG_BLACK BG_RED BG_GREEN BG_YELLOW BG_BLUE BG_MAGENTA BG_CYAN BG_WHITE

    # Font styles
    FS_REG="0m"
    FS_BOLD="1m"
    FS_UL="4m"
    export FS_REG FS_BOLD FS_UL
}

Mon_colorShell
F_log()
{
    texte="$1"
    [ -z "${texte}" ] && texte="UNDEFINED TEXT"
    errtype="$2" # INFO / WARN / ERROR
    [ -z "${errtype}" ] && errtype="INFO"
    datetime=$(date "+%Y/%m/%d %H:%M:%S")
    case "${errtype}" in
        INFO)   errtypeText="${FG_GREEN}${FS_BOLD}";;
        WARN)   errtypeText="${FG_YELLOW}${FS_BOLD}";;
        ERROR)  errtypeText="${FG_RED}${FS_BOLD}";;
        *)      ;;
    esac

    # Delete log file older than N days
    find ${SEARCHLOGFILE} -mtime +${NBDAYLOGFILE} -exec rm {} \; >/dev/null 2>&1

    [ -z "$SILENT" ] && printf "%s\t${errtypeText}%5s${RESET_ALL} - %s - %s\n" "${datetime}" "${errtype}" "${HOSTNAME}" "${texte}"
    printf "%s %5s - %s - %s\n" "${datetime}" "${errtype}" "${HOSTNAME}" "${texte}" >> ${LogFile} 2>&1
}


#******************************************************************
# Create ssh open connection between primary and standby
#******************************************************************
F_ssh_key()
{
PRIMARY_HOST=$1
STANDBY_HOST=$2
# Allow remote login without password prompt
[ ! -d  ~/.ssh ] && mkdir ~/.ssh
[ ! -f ~/.ssh/id_rsa ] && ssh-keygen -f ~/.ssh/id_rsa -t rsa -P ""
ssh-copy-id -i ~/.ssh/id_rsa.pub root@${STANDBY_HOST} 1>/dev/null 2>&1
# Allow loopback
ssh-copy-id -i ~/.ssh/id_rsa.pub root@${PRIMARY_HOST} 1>/dev/null 2>&1
# Allow standby to connect to primary without password
sshcmd='[ ! -d  ~/.ssh ] && mkdir ~/.ssh;[ ! -f ~/.ssh/id_rsa ] && ssh-keygen -f ~/.ssh/id_rsa -t rsa -P ""'
eval $sshcmd
ssh -q -C root@${STANDBY_HOST} $sshcmd 2>/dev/null
scp root@${STANDBY_HOST}:~/.ssh/id_rsa.pub ~/.ssh/${STANDBY_HOST}.pub 1>/dev/null 2>&1
ssh-copy-id -i ~/.ssh/${STANDBY_HOST}.pub root@${PRIMARY_HOST}  1>/dev/null 2>&1
# Remove duplicate keys
sshcmd='cp ~/.ssh/authorized_keys ~/.ssh/_authorized_keys;cat ~/.ssh/_authorized_keys|sort -u >~/.ssh/authorized_keys;rm  ~/.ssh/_authorized_keys'
eval $sshcmd
ssh -q -C root@${STANDBY_HOST} $sshcmd 2>/dev/null
}

#****************************************************************
# Generate KeyFile
#****************************************************************
F_gen_keyfile()
{
#set -x
typeset var WHOST=$1
typeset var LOCAL=`uname -n`

if [ "$WHOST" == "$LOCAL" ]
then
	if [ ! -f /mondata/cfg/mongodb-keyfile ]
	then
		openssl rand -base64 741 > /mondata/cfg/mongodb-keyfile
		chmod 600 /mondata/cfg/mongodb-keyfile
		chown mongodb:mongodb /mondata/cfg/mongodb-keyfile
	fi
else
        sshcmd='[ -f /mondata/cfg/mongodb-keyfile ] && exit 0 || exit 1'
	ssh -q -C root@${WHOST} $sshcmd 2>/dev/null
	if [ $? -eq 1 ]
        then		
		scp root@${LOCAL}:/mondata/cfg/mongodb-keyfile  root@${WHOST}:/mondata/cfg/mongodb-keyfile
		sshcmd='chown mongodb:mongodb /mondata/cfg/mongodb-keyfile'
	#	eval $sshcmd
		ssh -q -C root@${WHOST} $sshcmd 2>/dev/null
	fi
fi
}

#****************************************************************
# Kill processus
#****************************************************************
F_killAndWait()
{
    killall $1 2> /dev/null && wait $1 2> /dev/null
}

#***************************************************************
# Remove all components 
#***************************************************************
F_remove_all()
{
#set -x
typeset var WHOST=$1
typeset var WVERSION=$2
typeset var WVG=$3
typeset var WLV=$4
typeset var WFS_OPTION=$5
typeset var WMOUNT_POINT=$6

LOCAL=`uname -n`

[ -x `which yum` ] || return 1

if [ "$WHOST" == "$LOCAL" ]
then
	F_killAndWait mongod
	F_killAndWait mongos
    	find  ${WMOUNT_POINT}  -type d -exec fuser -k -9 {} \;
	for p in `yum list | grep mongo | awk '{print $1}'`
        do
         echo y | yum remove $p
        done
        #echo y | yum remove mongodb-orange-products-server-$WVERSION 
        #echo y | yum remove mongodb-orange-products-shell-$WVERSION 
        #echo y | yum remove mongodb-orange-products-tools-$WVERSION
	#echo y | yum remove mongodb-orange-products-mongos-$WVERSION
	umount ${WMOUNT_POINT}
	echo y | lvremove /dev/${WVG}/${WLV} 
	rm -rf ${WMOUNT_POINT}
        rm -rf /opt/mongodb/na
	rm -f /etc/logrotate.d/mongodb
	rm -rf /mondata/cfg/*
	rm -rf /mondata/config/*
	systemctl daemon-reload
else
        ssh  -T -C root@${WHOST} <<-EOSSH >> ${LogFile} 2>&1
	$(typeset -f F_killAndWait)
	F_killAndWait mongod	
	F_killAndWait mongos	
	find  ${WMOUNT_POINT}  -type d -exec fuser -k -9 {} \;
	#for p in `yum list|grep mongo|cut -d ' ' -f1`
        #do
	# echo -e "-----> pck $p"
        echo y | yum remove mongo*
        #done
        umount ${WMOUNT_POINT}
	echo y | lvchange -an /dev/${WVG}/${WLV} 
	echo y | lvremove /dev/${WVG}/${WLV} 
        rm -rf ${WMOUNT_POINT}
	rm -rf /opt/mongodb/na
	rm -f /etc/logrotate.d/mongodb
	rm -rf /mondata/cfg/*
	rm -rf /mondata/config/*
	systemctl daemon-reload

EOSSH
fi
return $?
}

#****************************************************************
# Install RPM
#****************************************************************
F_install_rpm()
{
#set -x
WHOST=$1
WVERSION=$2
WMONGOS=$3
LOCAL=`uname -n`

[  -x `which yum` ] || return 1
echo -e  "\t-------------------------"
echo -e  "\t----- $WHOST       ------"
echo -e  "\t-------------------------"

if [ "$WHOST" == "$LOCAL" ]
then
	echo y | yum install mongodb-orange-products-server-$WVERSION --enablerepo=nosql
	echo y | yum install mongodb-orange-products-shell-$WVERSION --enablerepo=nosql
	echo y | yum install mongodb-orange-products-tools-$WVERSION --enablerepo=nosql
	echo y | yum install mongodb-orange-tools --enablerepo=nosql

	if [ "$WMONGOS" == "1"  ]
	then
		echo ">>>>>>>>>>>>>>>>>>>>>>>install mongos"
		echo y | yum install mongodb-orange-products-mongos-$WVERSION --enablerepo=nosql  	
	fi
	systemctl daemon-reload
else
	ssh  -T -C root@${WHOST} <<-EOSSH > /dev/null 2>&1 	
	echo y | yum install mongodb-orange-products-server-$WVERSION --enablerepo=nosql
        echo y | yum install mongodb-orange-products-shell-$WVERSION --enablerepo=nosql
        echo y | yum install mongodb-orange-products-tools-$WVERSION --enablerepo=nosql
	echo y | yum install mongodb-orange-tools --enablerepo=nosql
	if [ "$WMONGOS" == "1"  ]
	then
		echo y | yum install mongodb-orange-products-mongos-$WVERSION --enablerepo=nosql  	
	fi
	systemctl daemon-reload
	EOSSH
fi
return $?
}

#***************************************************************
# F_disable_tph
#***************************************************************
F_disable_tph()
{
HOST=$1
LOCAL=`uname -n`

if [ `whoami` = "root" ]
then
        if [ "$HOST" == "$LOCAL" ]
        then
                echo "never" >/sys/kernel/mm/transparent_hugepage/enabled
                echo "never" >/sys/kernel/mm/transparent_hugepage/defrag
                grubby --update-kernel=ALL --args=transparent_hugepage=never
                echo -e " #!/bin/bash
### BEGIN INIT INFO
# Provides:          disable-transparent-hugepages
# Required-Start:    $local_fs
# Required-Stop:
# X-Start-Before:    mongod mongodb-mms-automation-agent
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# Short-Description: Disable Linux transparent huge pages
# Description:       Disable Linux transparent huge pages, to improve
#                    database performance.
### END INIT INFO

case \$1 in
  start)
    if [ -d /sys/kernel/mm/transparent_hugepage ]; then
      thp_path=/sys/kernel/mm/transparent_hugepage
    elif [ -d /sys/kernel/mm/redhat_transparent_hugepage ]; then
      thp_path=/sys/kernel/mm/redhat_transparent_hugepage
    else
      return 0
    fi

    echo 'never' > \${thp_path}/enabled
    echo 'never' > \${thp_path}/defrag
    re='^[0-1]+$'
    if [[ \$(cat \${thp_path}/khugepaged/defrag) =~ \$re ]]
    then
      # RHEL 7
      echo 0  > \${thp_path}/khugepaged/defrag
    else
      # RHEL 6
      echo 'no' > \${thp_path}/khugepaged/defrag
    fi

    unset re
    unset thp_path
    ;;
esac"  > /etc/init.d/disable-transparent-hugepages
        chmod 755 /etc/init.d/disable-transparent-hugepages
        chkconfig --add disable-transparent-hugepages

        else
	scp root@${LOCAL}:/etc/init.d/disable-transparent-hugepages root@${HOST}:/etc/init.d/disable-transparent-hugepages
        ssh -T -C root@${HOST}<<-EOSSH >> ${LogFile} 2>&1
                echo "never" >/sys/kernel/mm/transparent_hugepage/enabled
                echo "never" >/sys/kernel/mm/transparent_hugepage/defrag
                grubby --update-kernel=ALL --args=transparent_hugepage=never
        	chmod 755 /etc/init.d/disable-transparent-hugepages
        	chkconfig --add disable-transparent-hugepages
EOSSH
        fi
fi
}

#****************************************************************
# Create Repository
#****************************************************************
F_create_repo()
{
#set -x
typeset var WHOST=$1
LOCAL=`uname -n`

if [ "$WHOST" == "$LOCAL" ]
then
        if [ ! -f "/etc/yum.repos.d/nosql.repo" ]
        then
        echo -e '[nosql]\nname=nosql\nbaseurl="http://repoyum-central.itn.ftgroup/yum/repos/orange/product/nosql/el7/"\nenabled=0\ngpgcheck=0' >/etc/yum.repos.d/nosql.repo
        fi
else
	#debug mode 
	#ssh -v 
        ssh  -T -C root@${WHOST} <<-EOSSH 
        if [ ! -f "/etc/yum.repos.d/nosql.repo" ]
        then
        echo -e '[nosql]\nname=nosql\nbaseurl="http://repoyum-central.itn.ftgroup/yum/repos/orange/product/nosql/el7/"\nenabled=0\ngpgcheck=0' >/etc/yum.repos.d/nosql.repo
        fi
EOSSH
fi
return $?
}

#****************************************************************
# Create_lv_mondata
#****************************************************************
F_create_lv_mondata()
{
#set -x
typeset var WHOST=$1
typeset var WVG=$2
typeset var WLV=$3
typeset var WFS_OPTION=$4
typeset var WFS_SIZE=$5
typeset var WMOUNT_POINT=$6

LOCAL=`uname -n`

if [ "$WHOST" == "$LOCAL" ]
then
	if [ ! -e "${WMOUNT_POINT}"  ]
	then
		echo y | lvcreate -L $WFS_SIZE -n /dev/${WVG}/${WLV} ${WVG}
		cp -p /etc/fstab /etc/fstab.backup
		# Wait 2 seconds before creation FS - workaround msg in "use by the system will not make a filesystem"
		sleep 2
		if [ "${WFS_OPTION}" == "ext4" ]
		then 
			mkfs -t ext4 /dev/${WVG}/${WLV}
			[ `grep -c "/dev/${WVG}/${WLV}" /etc/fstab` -eq 0 ] && echo "/dev/${WVG}/${WLV} ${WMOUNT_POINT} ext4 defaults,nodev 1 2" >> /etc/fstab || ( F_Suppress_lines "\/dev\/${WVG}\/${WLV}" "${WFS_OPTION}" "/etc/fstab" ; echo "/dev/${WVG}/${WLV} ${WMOUNT_POINT} ext4 defaults,nodev 1 2" >> /etc/fstab)
		else
			mkfs.xfs -f /dev/${WVG}/${WLV}
			[ `grep -c "/dev/${WVG}/${WLV}" /etc/fstab` -eq 0 ] && echo "/dev/${WVG}/${WLV} ${WMOUNT_POINT} xfs defaults,nodev 1 2" >> /etc/fstab||( F_Suppress_lines "\/dev\/${WVG}\/${WLV}" "${WFS_OPTION}" "/etc/fstab" ;  echo "/dev/${WVG}/${WLV} ${WMOUNT_POINT}  xfs defaults,nodev 1 2" >> /etc/fstab)
		fi
		mkdir -p "${WMOUNT_POINT}"
		mount /dev/${WVG}/${WLV} "${WMOUNT_POINT}"
		[ $? -eq 0 ] || exit 1
		chown -R mongodb:mongodb "${WMOUNT_POINT}"
	fi
	
else
	ssh  -T -C root@${WHOST}<<-EOSSH >> ${LogFile} 2>&1
		#set -x
		$(typeset -f F_Suppress_lines)
		if [ ! -e "${WMOUNT_POINT}"  ]
		then
			echo ">>>>>>>>>>>>>>>>>>> je passe <<<<<<<<<<<<<<<<<<<<<<<<<<<"
			echo y | lvcreate -L $WFS_SIZE -n /dev/${WVG}/${WLV} ${WVG}
                	cp -p /etc/fstab /etc/fstab.backup
			sleep 2 
			if [ "${WFS_OPTION}" == "ext4" ]
                	then
				echo -e "@\t ${WHOST} -->mkfs"
                        	mkfs -t ext4 /dev/${WVG}/${WLV}
				[ `grep -c "/dev/${WVG}/${WLV}" /etc/fstab` -eq 0 ] && echo "/dev/${WVG}/${WLV} ${WMOUNT_POINT} ext4 defaults,nodev 1 2" >> /etc/fstab || ( F_Suppress_lines "\/dev\/${WVG}\/${WLV}" "${WFS_OPTION}" "/etc/fstab" ; echo "/dev/${WVG}/${WLV} ${WMOUNT_POINT} ext4 defaults,nodev 1 2" >> /etc/fstab)
                	else
                       		mkfs.xfs -f /dev/${WVG}/${WLV}
				[ `grep -c "/dev/${WVG}/${WLV}" /etc/fstab` -eq 0 ] && echo "/dev/${WVG}/${WLV} ${WMOUNT_POINT} xfs defaults,nodev 1 2" >> /etc/fstab||( F_Suppress_lines "\/dev\/${WVG}\/${WLV}" "${WFS_OPTION}" "/etc/fstab" ;  echo "/dev/${WVG}/${WLV} ${WMOUNT_POINT}  xfs defaults,nodev 1 2" >> /etc/fstab)
			fi
                mkdir -p "${WMOUNT_POINT}"
                mount /dev/${WVG}/${WLV} "${WMOUNT_POINT}"
                chown -R mongodb:mongodb "${WMOUNT_POINT}"
		fi
	EOSSH
fi
return $?
}

#****************************************************************
# F_alive_mongod
#****************************************************************
F_alive_mongod()
{
typeset var WHOST=$1

[ -z $WHOST ] && return 1

if [ "$WHOST" == `uname -n` ]
then
	pid_mongod=`pgrep -n mongod`
else
	sshcmd='pgrep -n mongod'
	eval $sshcmd
	pid_mongod=`ssh -q -C root@${WHOST} $sshcmd 2>/dev/null`
fi
[ "${pid_mongod}" -gt 0 ] && return 0 || return 1 
}

#****************************************************************
# F_status_mongodb
#****************************************************************
F_status_mongodb()
{
typeset var WHOST=$1
typeset var WHOST_TCP=$2
typeset var WUSER=$3
typeset var WPASSWORD=$4

if [ -z "${WUSER}" -a -z "${WPASSWORD}" ]
then
	su - mongodb <<EOF |tee -a ${LogFile} 2>&1
	mongo mongodb://$WHOST:$WHOST_TCP/admin --eval "db.serverStatus()"
EOF
else
	su - mongodb <<EOF |tee -a ${LogFile} 2>&1
	mongo mongodb://$WUSER:$WPASSWORD@$WHOST:$WHOST_TCP/admin --eval 'db.serverStatus()'
EOF
fi
return $?
}

#****************************************************************
# F_connect_rs
#****************************************************************
F_connect_rs()
{
#set -x
typeset var CONNECT_STRING=$1
typeset var WUSER=$2
typeset var WPASSWORD=$3
typeset var REPSET_NAME=$4

su - mongodb <<EOF |tee -a ${LogFile} 2>&1
mongo mongodb://$WUSER:$WPASSWORD@$CONNECT_STRING/admin?replicaSet=${REPSET_NAME} --eval "sleep(4000);rs.config()"
EOF
return $?
}

#****************************************************************
# F_cr_role_mongodb
# Before enabling authentification 
#****************************************************************
F_cr_role_mongodb()
{
#set -x
typeset var WHOST=$1
typeset var WHOST_TCP=$2
typeset var WROLE=$3
typeset var WRESOURCE=$4
typeset var WACTION=$5

su - mongodb <<EOF |tee -a ${LogFile} 2>&1
mongo mongodb://$WHOST:$WHOST_TCP/admin --eval 'db.createRole({ role: "${WROLE}", privileges: [{resource: {"${WRESOURCE}": true},actions:["${WACTION}"]}],roles:[] })'
 
EOF
return $?


}
#****************************************************************
# F_cr_user_mongodb
# Before enabling authentification 
#****************************************************************
F_cr_user_mongodb()
{
#set -x
typeset var WHOST=$1
typeset var WHOST_TCP=$2
typeset var WUSER=$3
typeset var WPASSWORD=$4
typeset var WROLE=$5
typeset var WROLE1=""

for i in $(echo $WROLE | tr "," "\n")
do
	if [ -z ${WROLE1} ]
	then 
		WROLE1="{role: \"$i\", db:\"admin\"}"
	else
		WROLE1="$WROLE1,{role: \"$i\", db:\"admin\"}"
	fi
done

su - mongodb <<EOF |tee -a ${LogFile} 2>&1
#mongo mongodb://$WHOST:$WHOST_TCP/admin --eval 'db.createUser({ user: "${WUSER}", pwd: "${WPASSWORD}", roles: [{role: "${WROLE}", db:"admin"}] })'
mongo mongodb://$WHOST:$WHOST_TCP/admin --eval 'db.createUser({ user: "${WUSER}", pwd: "${WPASSWORD}", roles: [$WROLE1]})'
EOF
return $?
}

#****************************************************************
# F_services_mongod
#****************************************************************
F_services_mongod()
{
typeset var WHOST=$1
ACTION=`echo $2 | tr '[:upper:]' '[:lower:]'`
LOCAL=`uname -n`

if [ `whoami` = "root" ]
then
        if [ "$WHOST" == "$LOCAL" ]
        then
                systemctl ${ACTION} mongod >> ${LogFile} 2>&1

                if [ $? -eq 0 ]
                then
                        echo "\t@ $action OK"
                        return 0
                else
                        echo "\t@ $action failed"
                        return 1
                fi
        else
                ssh -T -C root@${WHOST}<<-EOSSH >> ${LogFile} 2>&1
                systemctl ${ACTION} mongod
		EOSSH

                if [ $? -eq 0 ]
                then
                        echo "\t@ $action OK"
                        return 0
                else
                        echo "\t@ $action failed"
                        return 1
                fi
        fi
else
        echo "\@ only with root NOK"
        return 1
fi
}

#***************************************************************
# F_restart_process
#***************************************************************
F_restart_process()
{
typeset var WHOST=$1
typeset var WFICH=$2 
export WPID=$(basename -s .conf $WFICH).pid
LOCAL=`uname -n`

if [ `whoami` = "root" ]
then
        if [ "$WHOST" == "$LOCAL" ]
	then
		kill  $(cat /mondata/run/${WPID}) && ( wait 1 ; rm -f /mondata/config/mongod.lock )
		sleep 5
		su - mongodb -c "mongod --config ${WFICH} &"
	else
		
                ssh -T -C root@${WHOST}<<-EOSSH >> ${LogFile} 2>&1
		kill  $(cat /mondata/run/${WPID}) && ( wait 1 ; rm -f /mondata/config/mongod.lock )
		sleep 5
		su - mongodb -c "mongod --config ${WFICH} &"
EOSSH

	fi
fi
}

#****************************************************************
# F_create_record_rs
#****************************************************************
# Creates a replica set member's record for the configuration
#
# Arguments:
# $1 id
# $2 host
F_create_record_rs()
{
echo "{ \"_id\": $1, \"host\": \"$2\"}"
}

#****************************************************************
# F_init_rs
#****************************************************************
# Initialize the replica set
#
# Arguments:
# $1 primary host 
# $2 primary mongod port 
# $3 user 
# $4 password
# $5 replica set configuration record
#****************************************************************
F_init_rs() 
{
#set -x
typeset var WHOST=$1
typeset var WHOST_TCP=$2
typeset var WUSER=$3
typeset var WPASSWORD=$4
CFG_REC=$5

if [[ -z "$CFG_REC" ]]; then
echo "No configuration record passed"
exit 1
fi

cmd=`echo -e "rsconf = ${CFG_REC};rs.initiate(rsconf)"`

if [ -z $WUSER ]
then
echo "je passe"
su - mongodb <<EOF
 mongo mongodb://$WHOST:$WHOST_TCP/admin --eval '$cmd'
EOF
else
su - mongodb <<EOF 
 mongo mongodb://$WUSER:$WPASSWORD@$WHOST:$WHOST_TCP/admin --eval '$cmd'
EOF
fi

return $?
}

#****************************************************************
# F_run_mongos
#****************************************************************
F_run_mongos()
{
#set -x
typeset var WHOST=$1
typeset var WHOST_TCP=$2
typeset var WUSER=$3
typeset var WPASSWORD=$4
typeset var COMMAND=$5
LOCAL=`uname -n`
cmd=`echo -e "${COMMAND}"`

if [[ "$WHOST" == "$LOCAL" ]] || [[ "$WHOST" == "localhost" ]]
then
	if  [[ -z $WUSER ]] && [[ -z $WPASSWORD ]] 
	then  
		su - mongodb <<-EOF |tee -a ${LogFile} 2>&1
		mongo mongodb://$WHOST:$WHOST_TCP/admin --eval 'db.runCommand($cmd)'
	EOF
	else
		su - mongodb <<-EOF |tee -a ${LogFile} 2>&1
		mongo mongodb://$WUSER:$WPASSWORD@$WHOST:$WHOST_TCP/admin --eval 'db.runCommand($cmd)'
	EOF
	fi
else
        ssh -T -C root@${WHOST}<<-EOSSH >> ${LogFile} 2>&1
	if  [[ -z $WUSER ]] && [[ -z $WPASSWORD ]]
	then 
		su - mongodb <<-EOF 
		mongo mongodb://$WHOST:$WHOST_TCP/admin --eval 'db.runCommand($cmd)"'
	EOF
	else
		su - mongodb <<-EOF |tee -a ${LogFile} 2>&1
		mongo mongodb://$WUSER:$WPASSWORD@$WHOST:$WHOST_TCP/admin --eval 'db.runCommand($cmd)'
	EOF
	fi
EOSSH
fi

if [ $? -eq 0 ]
then
    echo "\t@ $action OK"
    return 0
else
 u  echo "\t@ $action failed"
    return 1
fi
}

#***************************************************************
# F_create_config()
#***************************************************************
F_create_config()
{
#set -x
typeset var WHOST=$1
typeset var FICH=$2
typeset var PORT=$3

#LOCAL=`uname -n`
LOCAL=NULL

if [ `whoami` = "root" ]
then
	export padding='\x20\x20\x20\x20'
	BINDIP=`ping -c 1 $WHOST | awk 'NR==1{gsub(/\(|\)/,"",$3);print $3}'`
	HEADER='
#-----------------------------------------------------------------------------------------------------
# Copyright(c) 2015 Orange SA
# This shell script is distributed under the LGPL v3.0 license (http://www.gnu.org/licenses/lgpl-3.0.html)
#
# NAME
#    config.conf
#
# DESCRIPTION
#    Config file for the config mongod process
#
# REMARKS
#
#    This file respect the Yaml Format
#
#    Prerequisites :
#       The Linux Tree has to respect the Linux Common Bundle Standards (Orange Group)
#	The config mongod is only mandatory for a sharding cluster
#
#    Input Parameters :
#       NA
#
#    Output :
#       NA
#
# CHANGE LOGS
#    Herve AGASSE (Orange/DSI/DESI/DIXI/PTAL/PRE) - 2018/03/13 - v1.0.0 - Creation
#---------------------------------------------------------------------------------------------'
	if [ "$WHOST" == "$LOCAL" ]
        then
                if [ -f "$FICH" ]
		then
			 cp "$FICH" "$FICH"_${date_YYYYMMDD}_${date_HHMMSS}
		fi	
		echo "$HEADER" > ${FICH}
	        new_section='storage:\n${padding}engine: wiredTiger\n${padding}dbPath: /mondata/config\n${padding}journal:\n${padding}${padding}enabled: true'
        	echo -e $new_section >> ${FICH}
	        new_section='processManagement:\n${padding}fork: true\n${padding}pidFilePath: /mondata/run/config.pid'
        	echo -e $new_section >> ${FICH}
	        #new_section='net:\n${padding}bindIp: 127.0.0.1,${BINDIP}\n${padding}port: ${PORT}\n${padding}unixDomainSocket:\n${padding}${padding}enabled: true\n${padding}${padding}pathPrefix: /data/cfg'
	        new_section='net:\n${padding}bindIp: 127.0.0.1,${BINDIP}\n${padding}port: ${PORT}'
        	echo -e $new_section >> ${FICH}
 		new_section='replication:\n${padding}replSetName: CREPSET'
        	echo -e $new_section >> ${FICH}
        	new_section='security:\n${padding}keyFile: /mondata/cfg/mongodb-keyfile\n${padding}authorization: enabled'
        	echo -e $new_section >> ${FICH}
        	new_section='systemLog:\n${padding}destination: file\n${padding}path: /mondata/log/config.log\n${padding}logAppend: true\n${padding}logRotate: reopen'
        	echo -e $new_section >> ${FICH}
	        new_section='sharding:\n${padding}clusterRole: configsvr'
        	echo -e $new_section >> ${FICH}
		chown mongodb:mongodb ${FICH}
		echo "local--> startup config mongod process" 
	 	mkdir -p /mondata/config
		chown mongodb:mongodb /mondata/config

		su - mongodb -c "mongod --config ${FICH} &"
	else
		ssh  -T -C root@${WHOST}<<-EOSSH >> ${LogFile} 2>&1
                       export new_section
	
                if [ -f "$FICH" ]
		then
			 cp "$FICH" "$FICH"_${date_YYYYMMDD}_${date_HHMMSS}
		fi	
		echo -e "${HEADER}" > "${FICH}"
	        #export new_section='\nstorage:\n    engine: wiredTiger\n    dbPath: /mondata/config'
	        #export new_section='storage:\n    engine: wiredTiger\n    dbPath: /mondata/config\n    journal:\n        enabled: true'
	        new_section='storage:\n${padding}engine: wiredTiger\n${padding}dbPath: /mondata/config\n${padding}journal:\n${padding}${padding}enabled: true'
		echo -e "\${new_section}" >> "${FICH}"
	        export new_section='processManagement:\n    fork: true\n    pidFilePath: /mondata/run/config.pid'
		echo -e "\${new_section}" >> "${FICH}"
	        #export new_section='net:\n${padding}bindIp: 127.0.0.1,${BINDIP}\n${padding}port: ${PORT}\n${padding}unixDomainSocket:\n${padding}${padding}enabled: true\n${padding}${padding}pathPrefix: /data/cfg'
	        export new_section='net:\n${padding}bindIp: 127.0.0.1,${BINDIP}\n${padding}port: ${PORT}'
		echo -e "\${new_section}" >> "${FICH}"
 		export new_section='replication:\n    replSetName: CREPSET'
		echo -e "\${new_section}" >> "${FICH}"
    #    	export new_section='security:\n    keyFile: /mondata/cfg/mongodb-keyfile\n    authorization: enabled'
        	export new_section='security:\n    keyFile: /mondata/cfg/mongodb-keyfile'
		echo -e "\${new_section}" >> "${FICH}"
        	export new_section='systemLog:\n    destination: file\n    path: /mondata/log/config.log\n    logAppend: true\n    logRotate: reopen'
		echo -e "\${new_section}" >> "${FICH}"
	        export new_section='sharding:\n    clusterRole: configsvr'
		echo -e "\${new_section}" >> "${FICH}"
		chown mongodb:mongodb ${FICH}
		echo "remote --> startup config mongod process" 
	 	mkdir -p /mondata/config
		chown mongodb:mongodb /mondata/config
		su - mongodb -c "mongod --config ${FICH} &"
	EOSSH
	fi
fi
}

#***************************************************************
# F_run_config
#***************************************************************
F_run_config()
{
#set -x
typeset var WHOST=$1
typeset var FICH=$2
typeset var PORT=$3
if [ "$WHOST" == "$LOCAL" ]
then
	su - mongodb -c "mongod --config ${FICH} --fork &" >> ${LogFile} 2>&1	
else
	ssh  -T -C root@${WHOST}<<-EOSSH >> ${LogFile} 2>&1	
	su - mongodb -c "mongod --config ${FICH} --fork &"
EOSSH
fi
}

#***************************************************************
# F_modify_Config_replicaset
# Modify the configuration for a replicaset
# echo -e \x20 -> ko in ksh93 ok bash and ksh
#***************************************************************
F_modify_Config_replicaset()
{
typeset var WHOST=$1
typeset var FICH=$2
REPLICAT_NAME=$3
LOCAL=`uname -n`

if [ `whoami` = "root" ]
then
        if [ "$WHOST" == "$LOCAL" ]
        then
                TROUVE=`egrep -c "# replication:" "$FICH"`
                if [ $TROUVE = 1 ]
                then
                        cp "$FICH" "$FICH"_${date_YYYYMMDD}_${date_HHMMSS}
                        chown mongodb:mongodb  "$FICH"_${date_YYYYMMDD}_${date_HHMMSS}
                        F_Suppress_lines "^replication:" "oplogSizeMB:" "$FICH"
                        F_Suppress_lines "^security:" "authorization:" "$FICH"
                        F_Suppress_lines "^systemLog:" "logAppend:" "$FICH"

                        new_section="replication:\n    replSetName: ${REPLICAT_NAME}\n    oplogSizeMB: 1024"

                        echo -e $new_section >> ${FICH}

                        new_section="security:\n    keyFile: /mondata/cfg/mongodb-keyfile\n    authorization: enabled"
                        echo -e $new_section >> ${FICH}

                        new_section='systemLog:\n    destination: file\n     path: /mondata/log/mongod.log\n    logAppend: true\n    logRotate: reopen'
                        echo -e $new_section >> ${FICH}

                fi
        else
                ssh -T -C root@${WHOST}<<-EOSSH >> ${LogFile} 2>&1
                        $(typeset -f F_Suppress_lines)
                        export new_section
                        TROUVE=`egrep -c "# replication:" "$FICH"`
                        if [ "\$TROUVE" = 1 ]
                        then
                                cp "$FICH" "$FICH"_${date_YYYYMMDD}_${date_HHMMSS}
                                F_Suppress_lines "^replication:" "oplogSizeMB:" "$FICH"
                                F_Suppress_lines "^security:" "authorization:" "$FICH"
                                F_Suppress_lines "^systemLog:" "logAppend:" "$FICH"
                                export new_section='replication:\n    replSetName: ${REPLICAT_NAME}\n    oplogSizeMB: 1024'
                                echo -e "\${new_section}" >> "${FICH}"
                                export new_section='security:\n    keyFile: /mondata/cfg/mongodb-keyfile\n    authorization: enabled'
                                echo -e "\${new_section}" >> "${FICH}"
                                export new_section='systemLog:\n    destination: file\n    path: /mondata/log/mongod.log\n    logAppend: true\n    logRotate: reopen'
                                echo -e "\${new_section}" >> "${FICH}"
                        fi
EOSSH
        fi
fi
}

#***************************************************************
# F_modify_mongos
# echo -e \x20 -> ko in ksh93 ok bash and ksh
#***************************************************************
F_modify_mongos()
{
typeset var WHOST=$1
typeset var FICH=$2
LOCAL=`uname -n`

if [ `whoami` = "root" ]
then
        if [ "$WHOST" == "$LOCAL" ]
        then
                TROUVE=`egrep -c "sharding:" "$FICH"`
                if [ $TROUVE = 1 ]
                then
                        cp "$FICH" "$FICH"_${date_YYYYMMDD}_${date_HHMMSS}
                        chown mongodb:mongodb  "$FICH"_${date_YYYYMMDD}_${date_HHMMSS}
                        F_Suppress_lines "^sharding:" "configDB:" "$FICH"
                        F_Suppress_lines "^systemLog:" "logAppend:" "$FICH"

			#new_section='processManagement:\n    fork: true\n    pidFilePath: /mondata/run/mongos.pid'
               		#echo -e $new_section >> ${FICH}

                        new_section='security:\n    keyFile: /mondata/cfg/mongodb-keyfile'
                        echo -e $new_section >> ${FICH}

                        new_section='systemLog:\n    destination: file\n     path: /mondata/log/mongos.log\n    logAppend: true\n    logRotate: reopen'
                        echo -e $new_section >> ${FICH}

			line_nb=0
			SHARD_STRING=""
			while [ $line_nb -lt ${#INFRA_HOSTS[@]} ]
			do
        		echo "----> hostname=${INFRA_HOSTS[$line_nb].hostname}"
		        if [ "${INFRA_HOSTS[$line_nb].hostname}" -a "${INFRA_HOSTS[$line_nb].type}" == "config" ]
        		then
				if [ -z $SHARD_STRING ]
				then
					SHARD_STRING=" CREPSET/${INFRA_HOSTS[$line_nb].hostname}:${INFRA_HOSTS[$line_nb].port}"
				else
					SHARD_STRING="${SHARD_STRING},${INFRA_HOSTS[$line_nb].hostname}:${INFRA_HOSTS[$line_nb].port}"
				fi
                        fi
			line_nb=$((line_nb+1))
			done

			new_section="sharding:\n    configDB:${SHARD_STRING}"
			echo -e $new_section >> ${FICH}

			su - mongodb -c "mongos --config ${FICH} --fork &" 
			sleep 10
                fi
        else
                ssh -T -C root@${WHOST}<<-EOSSH >> ${LogFile} 2>&1
                        $(typeset -f F_Suppress_lines)
                        export new_section
                        TROUVE=`egrep -c "sharding:" "$FICH"`
                        if [ "\$TROUVE" = 1 ]
                        then
				cp "$FICH" "$FICH"_${date_YYYYMMDD}_${date_HHMMSS}
       		                chown mongodb:mongodb  "$FICH"_${date_YYYYMMDD}_${date_HHMMSS}
                	        F_Suppress_lines "^sharding:" "configDB:" "$FICH"
                        	F_Suppress_lines "^systemLog:" "logAppend:" "$FICH"

			#	export new_section='processManagement:\n    fork: true\n    pidFilePath: /mondata/run/mongos.pid'
                	#	echo -e "\${new_section}" >> "${FICH}"

                       		export new_section='security:\n    keyFile: /mondata/cfg/mongodb-keyfile' 
				echo -e "\${new_section}" >> "${FICH}"

                        	export new_section='systemLog:\n    destination: file\n     path: /mondata/log/mongos.log\n    logAppend: true\n    logRotate: reopen'
                       		echo -e "\${new_section}" >> "${FICH}"
 
				line_nb=0
                        	SHARD_STRING=""
                        	while [ $line_nb -lt ${#INFRA_HOSTS[@]} ]
                       		do
                       			echo "----> hostname=${INFRA_HOSTS[$line_nb].hostname}"
                        		if [ "${INFRA_HOSTS[$line_nb].hostname}" -a "${INFRA_HOSTS[$line_nb].type}" == "config" ]
                       			then
                                		if [ -z $SHARD_STRING ]
                                		then
                                        		SHARD_STRING="CREPSET/${INFRA_HOSTS[$line_nb].hostname}:${INFRA_HOSTS[$line_nb].port}"
                                		else
                        	                	SHARD_STRING="${SHARD_STRING},${INFRA_HOSTS[$line_nb].hostname}:${INFRA_HOSTS[$line_nb].port}"
                                		fi
                        		fi
				line_nb=$((line_nb+1))
				done	
		
				export new_section='sharding:\n    configDB:${SHARD_STRING}'
				echo -e "\${new_section}" >> "${FICH}"	
				su - mongodb -c "mongos --config ${FICH} --fork &"
                        fi
EOSSH
        fi
fi
}

#***************************************************************
# F_create_logrotate
#***************************************************************
F_create_logrotate()
{
#set -x
HOST=$1
PROCESS=$2
LOCAL=`uname -n`

export WSCRIPT="/mondata/log/$PROCESS.log {
    daily
    rotate 30
    compress
    delaycompress
    dateext
    missingok
    notifempty
    create 0640 mongodb mongodb
    sharedscripts
    postrotate
        /bin/kill -SIGUSR1 \`cat /mondata/run/${PROCESS}.pid\` 2> /dev/null) 2> /dev/null || true
    endscript
}" 

if [ "$HOST" == "$LOCAL" ]
then
	if [ -f /etc/logrotate.d/mongodb ]
	then 
	[ `grep -c ${PROCESS} /etc/logrotate.d/mongodb` -eq 0 ] &&  echo -e "
/mondata/log/${PROCESS}.log {
    daily
    rotate 30
    compress
    delaycompress
    dateext
    missingok
    notifempty
    create 0640 mongodb mongodb
    sharedscripts
    postrotate
        /bin/kill -SIGUSR1 \`cat /mondata/run/${PROCESS}.pid\` 2> /dev/null) 2> /dev/null || true
    endscript
}" >> /etc/logrotate.d/mongodb

	else
echo -e "
/mondata/log/${PROCESS}.log {
    daily
    rotate 30
    compress
    delaycompress
    dateext
    missingok
    notifempty
    create 0640 mongodb mongodb
    sharedscripts
    postrotate
        /bin/kill -SIGUSR1 \`cat /mondata/run/${PROCESS}.pid\` 2> /dev/null) 2> /dev/null || true
    endscript
}" > /etc/logrotate.d/mongodb
	fi
        systemctl daemon-reload
else
        ssh -T -C root@${HOST}<<-EOSSH >> ${LogFile} 2>&1
	if [ -f /etc/logrotate.d/mongodb ]
        then
	[ `grep -c "\${PROCESS}" "/etc/logrotate.d/mongodb"` -eq 0 ] &&  
echo -e "
/mondata/log/${PROCESS}.log {
    daily
    rotate 30
    compress
    delaycompress
    dateext
    missingok
    notifempty
    create 0640 mongodb mongodb
    sharedscripts
    postrotate
        /bin/kill -SIGUSR1 \\\`cat /mondata/run/${PROCESS}.pid\\\` 2> /dev/null) 2> /dev/null || true
    endscript
}" >> /etc/logrotate.d/mongodb

	else
echo -e "
/mondata/log/${PROCESS}.log {
    daily
    rotate 30
    compress
    delaycompress
    dateext
    missingok
    notifempty
    create 0640 mongodb mongodb
    sharedscripts
    postrotate
        /bin/kill -SIGUSR1 \\\`cat /mondata/run/${PROCESS}.pid\\\` 2> /dev/null) 2> /dev/null || true
    endscript
}" > /etc/logrotate.d/mongodb
        fi
        systemctl daemon-reload
EOSSH
fi
return $?
}


#***************************************************************
# F_modify_BindIp
#***************************************************************
F_modify_BindIp()
{
#set -x
typeset var WHOST=$1
typeset var FICH=$2
LOCAL=`uname -n`

if [ `whoami` = "root" ]
then
        BINDIP=`ping -c 1 $WHOST | awk 'NR==1{gsub(/\(|\)/,"",$3);print $3}'`
        if [ "$WHOST" == "$LOCAL" ]
        then
		TROUVE=`egrep -c "$BINDIP" "$FICH"`
                if [ $TROUVE = 0 ]
                then
                        sed -i "s/bindIp: 127.0.0.1/bindIp: 127.0.0.1,${BINDIP}/" ${FICH}
                        return 0
                fi
        else
                ssh -T -C root@${WHOST}<<-EOSSH >> ${LogFile} 2>&1
		  	TROUVE=`egrep -c "$BINDIP" ${FICH}`
                        if [ "\${TROUVE}" = 0 ]
                        then
                        sed -i "s/bindIp: 127.0.0.1/bindIp: 127.0.0.1,${BINDIP}/" ${FICH}
                        fi
EOSSH
        fi
fi
}

#***************************************************************
# F_modify_Port
#***************************************************************
F_modify_Port()
{
#set -x
typeset var WHOST=$1
typeset var FICH=$2
typeset var WPORT=$3

LOCAL=`uname -n`

if [ `whoami` = "root" ]
then
        if [ "$WHOST" == "$LOCAL" ]
        then
                TROUVE=`egrep -c "$WPORT" "$FICH"`
                if [ $TROUVE = 0 ]
                then
                        sed -i "s/port: 27017/port: ${WPORT}/" ${FICH}
                        return 0
                fi
        else
                ssh  -T -C root@${WHOST}<<-EOSSH >> ${LogFile} 2>&1
                        TROUVE=`egrep -c "$WPORT" ${FICH}`
                        if [ "\${TROUVE}" = 0 ]
                        then
                        sed -i "s/port: 27017/port: ${WPORT}/" ${FICH}
                        fi
EOSSH
        fi
fi
}

#***************************************************************
# F_Suppress_lines
#***************************************************************
F_Suppress_lines()
{
DEBUT=$1
FIN=$2
FICH=$3
sed -i "/${DEBUT}/,/${FIN}/d" ${FICH}
return $?
}
 
#***************************************************************
# F_modify_ConfShard
# sharding:
#     clusterRole: configsvr|shardsvr
# replication:
#  replSetName: <replica set name>
# net:
#  bindIp: localhost,<ip address>
#***************************************************************
F_modify_ConfShard()
{
typeset var WHOST=$1
typeset var FICH=$2
NAME=$3
#LOCAL=`uname -n`
LOCAL=NULL 

if [ `whoami` = "root" ]
then
        if [ "$WHOST" == "$LOCAL" ]
        then
                TROUVE=`egrep -c "sharding:" "$FICH"`
                if [ $TROUVE = 1 ]
                then
                        cp "$FICH" "$FICH"_${date_YYYYMMDD}_${date_HHMMSS}
                        chown mongodb:mongodb  "$FICH"_${date_YYYYMMDD}_${date_HHMMSS}
                        F_Suppress_lines "^sharding:" "clusterRole" "$FICH"
                        if [ "$NAME"  == "CFG" ]
                        then
# Add configsrv ClusterRole + authentification after create users 
                        	#new_section='security:\n    keyFile: /mondata/cfg/mongodb-keyfile\n    authorization: enabled'
                        	#echo -e $new_section >> ${FICH}
                                new_section='sharding:\n   clusterRole: configsvr'
                        	echo -e $new_section >> ${FICH}

                        else
                                new_section='sharding:\n   clusterRole: shardsvr'
                        	echo -e $new_section >> ${FICH}
                        fi

                        #new_section='systemLog:\n    destination: file\n     path: /mondata/log/mongod.log\n    logAppend: true\n    logRotate: reopen'
                        #echo -e $new_section >> ${FICH}
                fi
        else
                ssh -T -C root@${WHOST}<<-EOSSH >> ${LogFile} 2>&1
                        $(typeset -f F_Suppress_lines)
                        export new_section
                        TROUVE=`egrep -c "sharding:" "$FICH"`
                        if [ "\$TROUVE" = 1 ]
                        then
                                cp "$FICH" "$FICH"_${date_YYYYMMDD}_${date_HHMMSS}
                                chown mongodb:mongodb  "$FICH"_${date_YYYYMMDD}_${date_HHMMSS}
                                F_Suppress_lines "^sharding:" "clusterRole" "$FICH"
                                if [ "$NAME"  == "CFG" ]
                                then
                                #	export new_section='security:\n    keyFile: /mondata/cfg/mongodb-keyfile\n    authorization: enabled'
                                #	echo -e "\${new_section}" >> "${FICH}"
                                        export new_section='sharding:\n   clusterRole: configsvr'
                                	echo -e "\${new_section}" >> "${FICH}"
                                else
                                        export new_section='sharding:\n   clusterRole: shardsvr'
                                	echo -e "\${new_section}" >> "${FICH}"
                                fi

                                #export new_section='systemLog:\n    destination: file\n    path: /mondata/log/mongod.log\n    logAppend: true\n    logRotate: reopen'
                                #echo -e "\${new_section}" >> "${FICH}"
                        fi
EOSSH
        fi
fi
}

#***************************************************************
# F_isNotSet
#***************************************************************
F_isNotSet()
{
#    [ ! ${!1} && ${!1-_} ]] && return 1 || return 0 
i=0
while [ $i -le ${#REPLICA_HOSTS[@]} ]
do
	if [ "${REPLICA_HOSTS[i].hostname}" == "$1" ]
	then
 	return 0
	fi
	i=$(($i+1))
done
return 1
}

#***************************************************************
# F_contains
# search if hostname exist or not in the main array
#***************************************************************
F_contains()
{
#set -x
#nameref list=$1
elem=$1
type=$2
line_nb=0
while [ $line_nb -lt ${#INFRA_HOSTS[@]} ]
do
        if [ "${INFRA_HOSTS[$line_nb].hostname}" ]
        then
                [ "${INFRA_HOSTS[$line_nb].hostname}" == "${elem}" -a "${INFRA_HOSTS[$line_nb].type}" == "${type}" ] && return 0
        fi

        line_nb=$((line_nb+1))
done

# echo "Could not find element"
return 1
}

#***************************************************************
# F_find_rs
# Search if hostname exist or not in the main array and returns 
# the name of replicaset associated 
#***************************************************************
F_find_rs()
{
#set -x
elem=$1
line_nb=0
while [ $line_nb -lt ${#REPLICA_HOSTS[@]} ]
do
        if [ "${REPLICA_HOSTS[$line_nb].hostname}" ]
        then
           [ "${REPLICA_HOSTS[$line_nb].hostname}" == "${elem}" ] && return ${line_nb} 
        fi
	line_nb=$((line_nb+1))
done

# echo "Could not find element"
return ""
}
#-------------------------------------------
# Main
#-------------------------------------------
echo "${reset}"

date_YYYYMMDD=`date +%Y%m%d`
date_HHMMSS=`date +%H%M%S`
LogFile=${LogFile-${PWD}/`basename $0 .sh`_${date_YYYYMMDD}_${date_HHMMSS}.log}
SEARCHLOGFILE=${PWD}/`basename $0 .sh`__??????_??????.log
NBDAYLOGFILE=30
SILENT=""

[ $# -ne 1 ] && { F_log "You must specify a config file" "ERROR" ; F_End 1  ; }

[ "$LOGNAME" = root ] || { F_log "You must be root." "ERROR" ; F_End 1 ; }

CONFIG_FILE=$1
[ -f "${CONFIG_FILE}" ] || { F_log "The config file doesn't exists." "ERROR"; F_End 1 ;}

#
# clear log file
echo "" > ${LogFile}
exec 2>&1 | tee  ${LogFile}
F_log "Parsing file started" "INFO"
#------------------------------------------
# Parse File
# ignore empty or comment line 
#------------------------------------------
typeset -a CONFIG_HOSTS
typeset -a CONFIG_PORTS
typeset -a USER
typeset -a PASSWORD
typeset -a ROLE
typeset -a ROLEMONGO
typeset -a RESOURCE
typeset -a ACTIONS
typeset -a key_labels
typeset -a REPSET_NAME
typeset -a VERSION
typeset -a SIZE_DATA
typeset -a FS
typeset -a VG
typeset -a LV
typeset -a FS_OPTION
typeset -a FS_SIZE
typeset -a POINT_MOUNT
typeset -a REPLICA_HOSTS
typeset -a MONGOS_HOSTS
typeset -a MONGOS_PORTS
typeset -a INFRA_HOSTS
typeset -a SHARD_HOSTS

key_labels=([replicaset]=replicaset
            [password]=password
            [role]=role
            [repset_name]=repset_name
            [version]=version
            [size]=size
	    [mount]=mount
            [config]=config
            [mongos]=mongos
            [shard]=shard	
           )

echo "-> ${key_labels[@]}"
# Initialize 
i=0 
j=0
k=0

cat ${CONFIG_FILE} | sed '/^[[:space:]]*\(#.*\)\?$/d' |
while IFS='=:' read -r key param1 param2 param3 param4 param5 
do
    printf '%s: %s:%s\n' "${key_labels[$key]}" "$param1" "$param2"
    case $key in
    replicaset)
        echo "$key = replicaset///"
        REPLICA_HOSTS[$i].rsname="$param1"  # replicaset name
        REPLICA_HOSTS[$i].hostname="$param2"  # hostname
        REPLICA_HOSTS[$i].port="$param3"  #  tcp port
        CONFIG_HOSTS+=("$param2")
        CONFIG_PORTS+=("$param3")
 	if [[ $(F_contains $param2 $key; echo $?) == 1 ]]	
	then 	 
		INFRA_HOSTS[$j].type="$key"
		INFRA_HOSTS[$j].hostname="$param2"
		INFRA_HOSTS[$j].port="$param3"
		j=$(($j+1))
	fi
	i=$(($i+1))
        ;;
    config)
        echo "$key = config server///"
 	if [[ $(F_contains $param1 $key; echo $?) == 1 ]]	
	then
		INFRA_HOSTS[$j].type="$key"
		INFRA_HOSTS[$j].hostname="$param1"
		INFRA_HOSTS[$j].port="$param2"
		j=$(($j+1))
	fi
        CONFIG_HOSTS+=("$param1")
        CONFIG_PORTS+=("$param2")
	;;
    password)
        echo "$key = password///"
        USER+=("$param1")
        PASSWORD+=("$param2")
	ROLE+=("$param3")
        ;;
    role)
        echo "$key = role///"
        ROLEMONGO+=("$param1")
        RESOURCE+=("$param2")
        ACTIONS+=("$param3")
        ;;
    repset_name)
	echo "key = repset_name///"
        REPSET_NAME="$param1"
	;;
    version)
	echo "key=version//"
	VERSION="$param1"
	;;
    size)
	echo "key=size//"
	SIZE_DATA="$param1"
	;;
    mount)
	echo "key=mount//"
	VG+=("$param1")
	LV+=("$param2")
	FS_OPTION+=("$param3")
	FS_SIZE+=("$param4")
	POINT_MOUNT+=("$param5")
	;;	
   mongos)
	echo "key=mongos//"
 	if [[ $(F_contains $param1 $key; echo $?) == 1 ]]	
	then
		INFRA_HOSTS[$j].type="$key"
		INFRA_HOSTS[$j].hostname="$param1"
		INFRA_HOSTS[$j].port="$param2"
		j=$(($j+1))
	fi
	MONGOS_HOSTS+=("$param1")
	MONGOS_PORTS+=("$param2")
	;;
   shard)
	echo "key=shard//"	
	SHARD_HOSTS[$k].shard=$param1
	SHARD_HOSTS[$k].hostname=$param2	
	k=$(($k+1))

    esac
done
echo "HOST-> ${CONFIG_HOSTS[@]}"
echo "REPLICASET-> ${#REPLICA_HOSTS[@]}"
echo "USER-> ${USER[@]}"
echo "USER-> ${USER[@]}"
echo "PASS-> ${PASSWORD[@]}"
echo "ROLE-> ${ROLE[@]}"
echo "VG-> ${VG[@]}"
echo "LV-> ${LV[@]}"
echo "FS_OPTION-> ${FS_OPTION[@]}"
echo "FS_SIZE-> ${FS_SIZE[@]}"
echo "POINT_MOUNT-> ${POINT_MOUNT[@]}"
echo "VERSION-> ${VERSION[@]}"
echo "INFRA_HOSTS.hostname => ${INFRA_HOSTS[@]}"
echo "SHARD_HOSTS.hostname => ${SHARD_HOSTS[@]}"
echo "REPLICA_HOSTS.hostname => ${REPLICA_HOSTS[@]}"

F_isNotSet "${CONFIG_HOSTS[1]}" 
if [ $? -ne 0 ]
then
  echo "${CONFIG_HOSTS[1]} is not set."
else
  echo "${CONFIG_HOSTS[1]} is  set."
fi
F_log "Parsing file ended" "INFO"
#---------------------------------
# Old  Parse file
#---------------------------------
#cpt_row=0
#sed '/^[[:space:]]*\(#.*\)\?$/d' $CONFIG_FILE >./new.txt
#line_nb=0
#for line in `cat ./new.txt`
#do
#CONFIG_HOSTS[$line_nb]=`echo $line|cut -d":" -f1`
#CONFIG_PORTS[$line_nb]=`echo $line|cut -d":" -f2`
#line_nb=$((line_nb+1))
#done
#echo "-> ${CONFIG_HOSTS[@]}"

#---------------------------------
# Configuring SSH keys
#---------------------------------
F_log "Configuring SSH Keys on all servers started" "INFO"

line_nb=0
while [ $line_nb -le ${#INFRA_HOSTS[@]} ]
do
	print ${INFRA_HOSTS[$line_nb].hostname}
	if [ "${INFRA_HOSTS[$line_nb].hostname}" == `uname -n` ]
    	then
       		 MASTER=${INFRA_HOSTS[$line_nb].hostname}
    	else
		if [ "${INFRA_HOSTS[$line_nb].hostname}" ]
		then
        	echo "Configuration certificat key MASTER/SLAVE : $MASTER -> ${INFRA_HOSTS[$line_nb].hostname}"
	        	F_ssh_key $MASTER ${INFRA_HOSTS[$line_nb].hostname}
		fi
    	fi

    	echo "MASTER=$MASTER"

        line_nb=$((line_nb+1))
done

F_log "Configuring SSH Keys on all servers ended" "INFO"

#---------------------------------
# RAZ 
#---------------------------------
F_log "Removing old installation started" "INFO"
line_nb=0
line_fs=0
while [ $line_nb -lt ${#INFRA_HOSTS[@]} ]
do
	while [ $line_fs -lt ${#POINT_MOUNT[@]} ]
	do
	echo "///// -> ${INFRA_HOSTS[$line_nb].hostname} \n "
	if [ "${VG[$line_fs]}" -a "${LV[$line_fs]}" -a "${FS_OPTION[$line_fs]}" -a "${FS_SIZE[$line_fs]}" -a "${POINT_MOUNT[$line_fs]}" ];
	then
	 #echo -e "REMOVE -> $POINT_MOUNT[$line_fs]"
    	 F_remove_all "${INFRA_HOSTS[$line_nb].hostname}" "${VERSION}" "${VG[$line_fs]}" "${LV[$line_fs]}" "${FS_OPTION[$line_fs]}" "${POINT_MOUNT[$line_fs]}" 2>/dev/null
	fi
	line_fs=$((line_fs+1))
	done
	line_fs=0
	line_nb=$((line_nb+1))
done
F_log "Removing old installation ended" "INFO"

#---------------------------------
# Install
#---------------------------------
# Creating LV, FS et directories
# Creating repository 
# Installing RPM
# Disabling TPH
# Configuring logrotate
# Adding IP and Port TCP
# Verifying service mongodb is UP 
#---------------------------------
F_log "Installing started" "INFO"
line_nb=0
line_fs=0
while [ $line_nb -le ${#INFRA_HOSTS[@]} ]
do
	if [ "${INFRA_HOSTS[$line_nb].hostname}" ]
	then	
		F_create_repo "${INFRA_HOSTS[$line_nb].hostname}"

		line_fs=0	

		while [ $line_fs -lt ${#POINT_MOUNT[@]} ]
		do	
			if [ "${VG[$line_fs]}" -a "${LV[$line_fs]}" -a "${FS_OPTION[$line_fs]}" -a "${FS_SIZE[$line_fs]}" -a "${POINT_MOUNT[$line_fs]}" -a "${INFRA_HOSTS[$line_nb].type}" == "replicaset"  ];
			then
				F_create_lv_mondata "${INFRA_HOSTS[$line_nb].hostname}" ${VG[$line_fs]} ${LV[$line_fs]} "${FS_OPTION[$line_fs]}" "${FS_SIZE[$line_fs]}" "${POINT_MOUNT[$line_fs]}"
			fi
			line_fs=$((line_fs+1))
		done

		# Vérify Mongod vs Mongos
		#F_isNotSet "${INFRA_HOSTS[$line_nb]}"

		if [ "${INFRA_HOSTS[$line_nb].type}" == "replicaset" ]
		then 
			F_log "Server Installation MONGOD" "INFO"
			F_install_rpm  "${INFRA_HOSTS[$line_nb].hostname}" "${VERSION}" 0 2>/dev/null
                        F_log "Disabling TPH" "INFO"
			F_disable_tph "${INFRA_HOSTS[$line_nb].hostname}"
			F_log "Creating LogRotate configuration" "INFO"
			F_create_logrotate "${INFRA_HOSTS[$line_nb].hostname}" mongod	
			F_log "Updating BindIp" "INFO"
			F_modify_BindIp "${INFRA_HOSTS[$line_nb].hostname}" "/mondata/cfg/mongod.conf"		
			F_log "Updating TCP Port" "INFO"
			F_modify_Port "${INFRA_HOSTS[$line_nb].hostname}" "/mondata/cfg/mongod.conf"  "${INFRA_HOSTS[$line_nb].port}"
			#F_services_mongod "${INFRA_HOSTS[$line_nb].hostname}" stop
			#F_services_mongod "${INFRA_HOSTS[$line_nb].hostname}" start
			#F_services_mongod "${INFRA_HOSTS[$line_nb].hostname}" status
		else
			if  [ "${INFRA_HOSTS[$line_nb].type}" == "mongos" ]
			then
				echo " MONGOS/////////////////////${INFRA_HOSTS[$line_nb].type} -- ${INFRA_HOSTS[$line_nb].hostname}" 
				# Context mongos server
				F_install_rpm  "${INFRA_HOSTS[$line_nb].hostname}" "${VERSION}" 1 2>/dev/null
				F_disable_tph "${INFRA_HOSTS[$line_nb].hostname}"
				F_create_logrotate "${INFRA_HOSTS[$line_nb].hostname}" mongos
				F_modify_BindIp "${INFRA_HOSTS[$line_nb].hostname}" "/mondata/cfg/mongos.conf"		
				F_modify_Port "${INFRA_HOSTS[$line_nb].hostname}" "/mondata/cfg/mongos.conf"  "${INFRA_HOSTS[$line_nb].port}"

			else
				if [ "${INFRA_HOSTS[$line_nb].type}" == "config" ]
				then
				F_install_rpm  "${INFRA_HOSTS[$line_nb].hostname}" "${VERSION}"  0 2>/dev/null
				F_disable_tph "${INFRA_HOSTS[$line_nb].hostname}"
	                        F_create_logrotate "${INFRA_HOSTS[$line_nb].hostname}" mongod
				fi
			fi
		fi
	fi
        line_nb=$((line_nb+1))
done

F_log "Installing  ended" "INFO"

#---------------------------------
# Generate KeyFile
#---------------------------------
F_log "Installing Keyfile started" "INFO"
line_nb=0
while [ $line_nb -le ${#INFRA_HOSTS[@]} ]
do
        if [ "${INFRA_HOSTS[$line_nb].hostname}"  -a "${INFRA_HOSTS[$line_nb].type}" == "replicaset"  ]
        then
                F_gen_keyfile "${INFRA_HOSTS[$line_nb].hostname}"
                if [ "$?" -eq 0 ]; then
                F_log "Generating keyfile  -  MongoDB on ${INFRA_HOSTS[$line_nb].hostname}" "INFO"
                else
                F_log "Generating keyfile -  MongoDB on ${CONFIG_HOSTS[$line_nb].hostname}" "ERROR"
                exit 1
                fi
        fi
        line_nb=$((line_nb+1))
done

F_log "Installing Keyfile ended" "INFO"
#---------------------------------
# Testing  Alive && Connecting
#---------------------------------
F_log "Testing alive and connecting started" "INFO"
line_nb=0
while [ $line_nb -le ${#INFRA_HOSTS[@]} ]
do
	if [ "${INFRA_HOSTS[$line_nb].hostname}" ]
	then	
		if [ "${INFRA_HOSTS[$line_nb].type}" == "replicaset" ]
		then		
			F_services_mongod "${INFRA_HOSTS[$line_nb].hostname}" stop
                        F_services_mongod "${INFRA_HOSTS[$line_nb].hostname}" start
			F_alive_mongod "${INFRA_HOSTS[$line_nb].hostname}"
			if [ "$?" -eq 0 ]; then
  				F_log "MongoDB ${INFRA_HOSTS[$line_nb].hostname} alive" "INFO"
				#F_status_mongodb  "${INFRA_HOSTS[$line_nb].hostname}" "${INFRA_HOSTS[$line_nb].port}" ${USER} ${PASSWORD}
				F_status_mongodb  "${INFRA_HOSTS[$line_nb].hostname}" "${INFRA_HOSTS[$line_nb].port}"
				if [ "$?" -eq 0 ]; then
  					F_log "${INFRA_HOSTS[$line_nb].hostname} connecting on port ${INFRA_HOSTS[$line_nb].port}" "INFO"
				else
  					F_log "${INFRA_HOSTS[$line_nb].hostname} connecting on port ${INFRA_HOSTS[$line_nb].port}" "ERROR"
					exit 1
				fi	
		
			else
 				F_log  "MongoDB on ${INFRA_HOSTS[$line_nb]} not alive" "ERROR"
               			exit 1
			fi
		elif [ "${INFRA_HOSTS[$line_nb].type}" == "config" ]
			then
				F_create_config "${INFRA_HOSTS[$line_nb].hostname}" /mondata/cfg/config.conf "${INFRA_HOSTS[$line_nb].port}"	
				F_alive_mongod "${INFRA_HOSTS[$line_nb].hostname}"
                   	     	if [ "$?" -eq 0 ]; then
                               		F_log "Config Server - ${INFRA_HOSTS[$line_nb].hostname} alive" "INFO"
                                	F_status_mongodb  "${INFRA_HOSTS[$line_nb].hostname}" "${INFRA_HOSTS[$line_nb].port}"
                                	if [ "$?" -eq 0 ]; then
                                       		F_log "${INFRA_HOSTS[$line_nb].hostname} connecting on port ${INFRA_HOSTS[$line_nb].port}" "INFO"
                                	else
                                       		F_log "${INFRA_HOSTS[$line_nb].hostname} connecting on port ${INFRA_HOSTS[$line_nb].port}" "ERROR"
                                        	exit 1
                                	fi
                        	else
                                	F_log "Config Server - ${INFRA_HOSTS[$line_nb].hostname} not alive" "ERROR"
                                	exit 1
                       		fi
		elif [ "${INFRA_HOSTS[$line_nb].type}" == "mongos" ]
			then
				echo "------> MONGOS" 
				F_modify_mongos "${INFRA_HOSTS[$line_nb].hostname}" /mondata/cfg/mongos.conf
 
		fi
        fi
	line_nb=$((line_nb+1))
done
F_log "testing alive and connecting ended" "INFO"
#---------------------------------
# Creating users into DB ADMIN 
#---------------------------------
F_log "Creating users and roles started"  "INFO"
#---------------------------------

line_nb=0
while [ $line_nb -le ${#INFRA_HOSTS[@]} ]
do
#        if [[ "${INFRA_HOSTS[$line_nb]}.hostname" ]] && [[ "${INFRA_HOSTS[$line_nb].type}" == "replicaset"  || "${INFRA_HOSTS[$line_nb].type}" == "config" ]]
        if [[ "${INFRA_HOSTS[$line_nb]}.hostname" ]] && [[ "${INFRA_HOSTS[$line_nb].type}" == "replicaset" ]]
        then
		user_nb=0
                while [ $user_nb -le ${#ROLEMONGO[@]} ]
                do
                        if [ $user_nb -eq 0 ];
                        then
                        echo -e "\nROLE> ${ROLEMONGO[@]}"
                        echo -e "RESOURCE-> ${RESOURCE[@]}"
                        echo -e "ACTIONS-> ${ACTIONS[@]}"
                        fi

                        echo -e "\t@ compteur=$user_nb  ----> ${ROLE[$user_nb]}\n ${RESOURCE[$user_nb]}"
                        if [  "${ROLEMONGO[$user_nb]}" -a "${RESOURCE[$user_nb]}"  -a "${ACTIONS[$user_nb]}" ]
                        then
                                F_cr_role_mongodb "${INFRA_HOSTS[$line_nb].hostname}" "${INFRA_HOSTS[$line_nb].port}" "${ROLEMONGO[$user_nb]}" "${RESOURCE[$user_nb]}" "${ACTIONS[$user_nb]}"
                                if [ "$?" -eq 0 ]; then
                                        F_log "Creating role ${ROLEMONGO[$user_nb]} on ${INFRA_HOSTS[$line_nb].hostname}" "INFO"
                                else
                                        F_log "Creating role ${ROLEMONGO[$user_nb]} on ${INFRA_HOSTS[$line_nb].hostname}" "ERROR"
                                #       exit 1
                                fi
                        fi
                        user_nb=$((user_nb+1))
                done

		user_nb=0
		while [ $user_nb -le ${#USER[@]} ]
		do
			if [ $user_nb -eq 0 ];
			then
			echo -e "\nUSER-> ${USER[@]}"
			echo -e "PASS-> ${PASSWORD[@]}"
			echo -e "ROLE-> ${ROLE[@]}"
			fi

			echo -e "\t@ compteur=$user_nb  ----> ${USER[$user_nb]}\n ${PASSWORD[$user_nb]}"
			if [  "${USER[$user_nb]}" -a "${PASSWORD[$user_nb]}"  -a "${ROLE[$user_nb]}" ]
			then 
				F_cr_user_mongodb "${INFRA_HOSTS[$line_nb].hostname}" "${INFRA_HOSTS[$line_nb].port}" "${USER[$user_nb]}" "${PASSWORD[$user_nb]}" "${ROLE[$user_nb]}"
				if [ "$?" -eq 0 ]; then
					F_log "Creating user ${USER[$user_nb]} on ${INFRA_HOSTS[$line_nb].hostname}" "INFO"
                                else
                        		F_log "Creating user ${USER[$user_nb]} on ${INFRA_HOSTS[$line_nb].hostname}" "ERROR"
                        	#	exit 1
				fi
			fi
        		user_nb=$((user_nb+1))
		done		
        fi
        line_nb=$((line_nb+1))
done
F_log "Creating users and roles ended"  "INFO"

#-----------------------------------------------------------
# Modifying config file
# Adding localhost IP into parameter bindIp 
# Activating authentification and replicaset configuration 
#----------------------------------------------------------
F_log "Updating config file started"  "INFO"
line_nb=0
while [ $line_nb -le ${#REPLICA_HOSTS[@]} ]
do
	if [ "${REPLICA_HOSTS[$line_nb].hostname}" ]
        then
		#F_modify_BindIp "${REPLICA_HOSTS[$line_nb]}" "/mondata/cfg/mongod.conf"
		F_modify_Config_replicaset "${REPLICA_HOSTS[$line_nb].hostname}" "/mondata/cfg/mongod.conf" "${REPLICA_HOSTS[$line_nb].rsname}"
		F_services_mongod "${REPLICA_HOSTS[$line_nb].hostname}" stop
		if [ $? -eq 1 ]
		then
			F_log "Stopping server mongod : ${REPLICA_HOSTS[$line_nb].hostname}" "ERROR" 
			exit 1
		fi

		F_services_mongod "${REPLICA_HOSTS[$line_nb].hostname}" start
		if [ $? -eq 1 ]
		then
			F_log "Starting server mongod : ${REPLICA_HOSTS[$line_nb].hostname}" "ERROR"
			exit 1
		else
			 F_services_mongod "${REPLICA_HOSTS[$line_nb].hostname}" status	
		fi
	fi

	line_nb=$((line_nb+1))
done

#debug#
# setup the config replica set. Only neccessary on first launch
#IFS=':' read -r config0 <<< ${CONFIG_HOSTS[0]}
#su - mongodb <<-EOF |tee -a ${LogFile} 1>&3 2>&1
#mongo mongodb://${USER}:${PASSWORD]@${config0[0]}  --eval "rs.initiate( { _id: \"conf\", members: [ {_id: 0, host:\"${CONFIG[0]}\"}, {_id: 1, host:\"${CONFIG[1]}\"}, {_id: 2, host:\"${CONFIG[2]}\"} ]})"&
#EOF
F_log "Updating config file ended"  "INFO"

#-----------------------------------------------------------
# Preparing Configuration Replicaset
# Connecting user must be root to iniatialize replication
# Think to declare the first user in the server mongodb with the role root !
#-----------------------------------------------------------
F_log "Preparing replicaset configuration - started"  "INFO"

line_nb=0
MEMBERS=""
CONNECT_STRING=""
RSNAME=${REPLICA_HOSTS[0].rsname}
WRSNAME=0

while [ $line_nb -lt ${#REPLICA_HOSTS[@]} ]
do
	echo "----> hostname=${REPLICA_HOSTS[$line_nb].hostname} ////   rsname=${REPLICA_HOSTS[$line_nb].rsname}" 
	while [ "${REPLICA_HOSTS[$line_nb].rsname}" == "${RSNAME}" ]  
       	do
       		if [ "${REPLICA_HOSTS[$line_nb].hostname}" ]
		then
			if [ -z $MEMBERS ]
		   	then
				CONNECT_STRING="${CONNECT_STRING}${REPLICA_HOSTS[$line_nb].hostname}:${REPLICA_HOSTS[$line_nb].port}"
				MEMBERS="$MEMBERS `F_create_record_rs $(($line_nb - $WRSNAME)) "${REPLICA_HOSTS[$line_nb].hostname}":"${REPLICA_HOSTS[$line_nb].port}"`"	
		   	else
				MEMBERS="${MEMBERS},`F_create_record_rs $line_nb "${REPLICA_HOSTS[$line_nb].hostname}":"${REPLICA_HOSTS[$line_nb].port}"`"
				CONNECT_STRING="${CONNECT_STRING},${REPLICA_HOSTS[$line_nb].hostname}:${REPLICA_HOSTS[$line_nb].port}"
				RSNAME=${REPLICA_HOSTS[$line_nb].rsname}
	  		fi
		fi
	       	line_nb=$((line_nb+1))
	done

	echo "[INFO] Configuring replica set ${RSNAME} and initializing"
	CONFIG="{ _id: \"${RSNAME}\", members: [${MEMBERS}]}"
	 
	F_init_rs "${REPLICA_HOSTS[$WRSNAME].hostname}" "${REPLICA_HOSTS[WRSNAME].port}" "${USER}" "${PASSWORD}" "${CONFIG}"
	if [[ $? != 0 ]]; then
	        F_log "could not initialize the replica set [${RSNAME}]" "ERROR"
       		exit 1
	else
       		F_log "Replica set ${RSNAME} started and configured" "INFO"
		echo "@\t#-----------------------------------------------------------"
		echo "@\t# Testing connexion with replicaset configuration"
		echo "@\t#-----------------------------------------------------------"
		sleep 20
		F_connect_rs "${CONNECT_STRING}" "${USER}" "${PASSWORD}" "${RSNAME}"
		F_status_mongodb  "${REPLICA_HOSTS[$WRSNAME].hostname}" "${REPLICA_HOSTS[WRSNAME].port}" ${USER} ${PASSWORD}

		#WRSNAME=$(($line_nb -1)) # 
		WRSNAME=$line_nb 
		CONFIG=""
		MEMBERS=""
		RSNAME=${REPLICA_HOSTS[$WRSNAME].rsname}
		CONNECT_STRING="${REPLICA_HOSTS[$WRSNAME].hostname}:${REPLICA_HOSTS[$WRSNAME].port}"
		MEMBERS="`F_create_record_rs $(($line_nb - $WRSNAME)) "${REPLICA_HOSTS[$WRSNAME].hostname}":"${REPLICA_HOSTS[$WRSNAME].port}"`"	
	fi			
 
       line_nb=$((line_nb+1))
done

if [[ ! -z ${RSNAME} ]] && [[ ! -z ${MEMBERS} ]]
then 
	F_log "Configuring next replica set ${RSNAME} and initializing started"
	CONFIG="{ _id: \"${RSNAME}\", members: [${MEMBERS}]}"
	F_init_rs "${REPLICA_HOSTS[$WRSNAME].hostname}" "${REPLICA_HOSTS[WRSNAME].port}" "${USER}" "${PASSWORD}" "${CONFIG}"
	if [[ $? != 0 ]]; then
		F_log "could not initialize the replica set [${RSNAME}]" "ERROR"
		exit 1
	else
	F_log "Replica set ${WRSNAME} started and configured" "INFO"
	echo "@\t#-----------------------------------------------------------"
	echo "@\t# Testing connexion with replicaset configuration : $RSNAME"
	echo "@\t#-----------------------------------------------------------"
	sleep 20
	F_connect_rs "${CONNECT_STRING}" "${USER}" "${PASSWORD}" "${RSNAME}"
	F_status_mongodb "${REPLICA_HOSTS[$WRSNAME].hostname}" "${REPLICA_HOSTS[WRSNAME].port}" ${USER} ${PASSWORD}
	fi
fi

F_log "Preparing replicaset configuration - ended"  "INFO"
#-----------------------------------------------------------
# Preparing Configuration for the config servers
# Connecting user must be root to iniatialize replication
# Think to declare the first user in the server mongodb with the role root !
#-----------------------------------------------------------
if [[ ! -z ${MONGOS_HOSTS[0]} ]] && [[ ! -z ${MONGOS_PORTS[0]} ]]
then
F_log "Preparing replicaset configuration for config servers (sharded environment) - started"  "INFO"
line_nb=0
MEMBERS=""
CONNECT_STRING=""

while [ $line_nb -lt ${#INFRA_HOSTS[@]} ]
do
	if [ ${INFRA_HOSTS[$line_nb].type} == "config" ]
	then 
	 	F_modify_ConfShard "${INFRA_HOSTS[$line_nb].hostname}" "/mondata/cfg/config.conf" CFG	
		F_restart_process "${INFRA_HOSTS[$line_nb].hostname}" "/mondata/cfg/config.conf"
 	 	if [ -z $MEMBERS ]
                then
		     WRSNAME=$line_nb
                     CONNECT_STRING="${CONNECT_STRING}${INFRA_HOSTS[$line_nb].hostname}:${INFRA_HOSTS[$line_nb].port}"
                     MEMBERS="$MEMBERS `F_create_record_rs $(($line_nb - $WRSNAME)) "${INFRA_HOSTS[$line_nb].hostname}":"${INFRA_HOSTS[$line_nb].port}"`"
                else
                     MEMBERS="${MEMBERS},`F_create_record_rs $(($line_nb - $WRSNAME)) "${INFRA_HOSTS[$line_nb].hostname}":"${INFRA_HOSTS[$line_nb].port}"`"
                     CONNECT_STRING="${CONNECT_STRING},${INFRA_HOSTS[$line_nb].hostname}:${INFRA_HOSTS[$line_nb].port}"
                fi
	fi
        line_nb=$((line_nb+1))
done
sleep 10

if [[ ! -z $MEMBERS ]] && [[ ! -z $CONNECT_STRING ]] 
then 
	echo "[INFO] Configuring replica set config server CREPSET and initializing"
	CONFIG="{ _id: \"CREPSET\", configsvr: true, members: [${MEMBERS}]}"
#	F_init_rs "${INFRA_HOSTS[$WRSNAME].hostname}" "${INFRA_HOSTS[WRSNAME].port}" ${USER} ${PASSWORD} "${CONFIG}"
#	F_init_rs "${INFRA_HOSTS[$WRSNAME].hostname}" "${INFRA_HOSTS[WRSNAME].port}" "" "" "${CONFIG}"
#    localhost interface !!!!
	F_init_rs localhost "${INFRA_HOSTS[WRSNAME].port}" "" "" "${CONFIG}"

	if [[ $? != 0 ]]; then
		F_log "could not initialize the replica set CREPSET" "ERROR"
		exit 1
	else
		F_log "Replica set CREPSET started and configured" "INFO"
	fi
fi
sleep 30
F_log "Preparing replicaset configuration for config servers (sharded environment) - ended"  "INFO"
fi
#--------------------------------------------------------
# Sharding
# db.runCommand({addShard:"SH1/dvxx2asc8m:27017,dvxx2asc8n:27018,dvxx2asc8p:27019"})
#--------------------------------------------------------
line_nb=0
line_nb1=0
line_nb2=0
WRSNAME=0
RSNAME=""
WSHARD=""

# create user localhost exception
if [[ ! -z ${MONGOS_HOSTS[0]} ]] && [[ ! -z ${MONGOS_PORTS[0]} ]]
then
	F_log "Preparing sharding configuration  - started"  "INFO"
	cmd=$(echo "db.getSiblingDB(\"admin\").createUser({user:\"root\",pwd:\"root-mongo\",roles:[{\"role\":\"root\",\"db\":\"admin\"}]})")
	#F_run_mongos localhost "${MONGOS_PORTS[0]}" "" "" ${cmd}
	F_cr_user_mongodb localhost "${MONGOS_PORTS[0]}" "${USER[0]}" "${PASSWORD[0]}" "root"

while [ $line_nb -lt ${#SHARD_HOSTS[@]} ]
do
	echo "  boucle shard -> $line_nb "
	NB=$(F_find_rs "${SHARD_HOSTS[$line_nb].hostname}";echo $?)
	RSNAME=${REPLICA_HOSTS[$NB].rsname}
	echo "rsname--> ${RSNAME}"
	if [ !  -z "${RSNAME}" ] 
	then
		while  [[ $line_nb1 -lt ${#REPLICA_HOSTS[@]} ]] && [[ "${REPLICA_HOSTS[$line_nb1].rsname}" ==  "${RSNAME}" ]]
		do
			F_modify_ConfShard "${REPLICA_HOSTS[$line_nb1].hostname}" "/mondata/cfg/mongod.conf" SHARD
			F_services_mongod "${REPLICA_HOSTS[$line_nb1].hostname}" stop
	                F_services_mongod "${REPLICA_HOSTS[$line_nb1].hostname}" start
			if [ -z "${WSHARD}" ]
			then
				WSHARD="{addShard:\"${REPLICA_HOSTS[$line_nb1].rsname}/${REPLICA_HOSTS[$line_nb1].hostname}:${REPLICA_HOSTS[$line_nb1].port}"
			else
				WSHARD="$WSHARD,${REPLICA_HOSTS[$line_nb1].hostname}:${REPLICA_HOSTS[$line_nb1].port}"
			fi 
			line_nb1=$((line_nb1+1))	
		done
# Finalize command 
		WSHARD="$WSHARD\"}"
# Relaunch config servers if stopped!

		while [ $line_nb2 -lt ${#INFRA_HOSTS[@]} ]
		do
			if [ "${INFRA_HOSTS[$line_nb2].type}" == "config" ]	
			then
                		F_run_config "${INFRA_HOSTS[$line_nb2].hostname}" /mondata/cfg/config.conf "${INFRA_HOSTS[$line_nb2].port}"
			fi
			line_nb2=$((line_nb2+1))
		done	
		echo "*----------------------------"
		echo "--> ADD SHARD --> $WSHARD"    
		echo "*----------------------------"
		F_run_mongos "${MONGOS_HOSTS[0]}" "${MONGOS_PORTS[0]}" ${USER} ${PASSWORD} "${WSHARD}"
		# Backup current rsname
		RSNAME=${REPLICA_HOSTS[$line_nb1].rsname}
		echo "RSNAME = $RSNAME "
		echo "cpt boucle replicaset -> $line_nb1"
        else
		F_log "the server ${SHARD_HOSTS[$line_nb].hostname} does not exist in a replicaset" "ERROR"
		exit  1
	fi

	WSHARD=""
	line_nb2=0
	line_nb=$((line_nb+1))
	F_log "Preparing sharding configuration  - ended"  "INFO"
done
	F_log "Testing  connexion in sharding configuration  - started"  "INFO"
# connexion test and view sharding configuration
	F_run_mongos "${MONGOS_HOSTS[0]}" "${MONGOS_PORTS[0]}" ${USER} ${PASSWORD} "sh.status()"
	F_log "Testing  connexion in sharding configuration  - ended"  "INFO"

# connexion replicaset test
	line_nb=0
	while  [[ $line_nb -lt ${#REPLICA_HOSTS[@]} ]] 
	do
		F_connect_rs "${REPLICA_HOSTS[$line_nb].hostname}:${REPLICA_HOSTS[$line_nb].port}" "${USER}" "${PASSWORD}" "${REPLICA_HOSTS[$line_nb].rsname}"
		line_nb=$((line_nb+1))
	done
fi
#

#---------------------------------------------------------
# END 
#---------------------------------------------------------
unset all
exit 0

