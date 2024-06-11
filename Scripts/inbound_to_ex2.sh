#!/usr/bin/ksh
# +-----------------------------------------------------------------------------------------------+
# ID             : inbound_to_ex2.ksh
# NAME           : inbound_to_ex2.ksh
# PURPOSE        : Transfer package files from NAS path to EX2
# PARAMETERS     : 1 = Environment Name, 2 = Application name, 3 = FILENAME
# SYNTAX         : inbound_to_ex2.ksh $1 $2 $3 (where $1= DEV, TEST, UAT, PROD etc. $3= FILENAME)
# ENVIRONMENT    : LINUX
# PROJECT        : EX2
# AREA           : Aspera to EX2 file transfer
# +-----------------------------------------------------------------------------------------------+
# +--------------------- Revision Record ---------------------------------------------------------+
# Version       Date            Author                       Description
# EX2 2.0     20-May-2024     Nitesh Jyotirmay               Initial version as per RS
# EX2 2.0     04-Jun-2024     Rehan Sayyed                   Enhanced script usign functions
# +-----------------------------------------------------------------------------------------------+

# Set Script Variables
echo "inbound_to_ex2"
export SOURCE_PATH="/opt/ex2dev/ex2/scripts_dir"
MESSAGE_FLAG=0
FNAM=`basename $3 .zip`
echo $FNAM
export BAD_FILE_DIR="/opt/ex2dev/ex2share/ex2_staging_dev/EX2/bad_dir"
export NL=$'\n'
export SFTP_LOG_MESSAGE="Error Logging for INBOUND to EX2 Transfer Started. Start Time: `date`"
export SFTP_LOG=$SOURCE_PATH/logs/inbound_to_ex2_errors_$(date +"%y%m%d%H%M%S").log
export LOG_FILE=$LOG_DIR/${FNAM}_inbound_to_ex2_$(date +"%y%m%d%H%M%S").log
MESSAGE_FLAG=0
export ORACLE_HOME=/opt/oracle/orauser/product/19.0.0/client_64
export LD_LIBRARY_PATH=/opt/oracle/orauser/product/19.0.0/client_64/lib
export DB_USER=EX2APP
export DB_PASS=`openssl aes-256-cbc -a -d -in $SOURCE_PATH/conf/DB_details -k test123`
export ORACLE_SID=EX2DEV01AWS
echo "reading2"

# Function to log information
print_log_info() {
    /bin/echo "-------------------------------------------------------------------------------------------------------------------------------------" | tee -a $1
    /bin/echo "Start Time:" `date` >> $1
    /bin/echo "APP:" $APP >> $1
    /bin/echo "ENV:" $ENV >> $1
    /bin/echo "DIR:" $DIRC >> $1
    /bin/echo "LOG_DIR:" $LOG_DIR >> $1
    /bin/echo "LOG_FILE:" $LOG_FILE >> $1
    /bin/echo "FILE_NM_PATERN:" $FILE_NM_PATERN >> $1
    /bin/echo "INBOUND_DIR:" $SOURCE_DIR >> $1
    /bin/echo "INBOUND_SERVER:" $TGT_SERVER >> $1
    /bin/echo "EX2_DIR:" $TARGET_DIR >> $1
}

# Function to check if the package exists in the database
is_package_exists() {
    typeset -u PACKNAME=$1
    $ORACLE_HOME/bin/sqlplus -s $DB_USER/$DB_PASS@$ORACLE_SID <<EOF
set heading off
set feedback off
spool $SOURCE_PATH/logs/${FNAM}_packname_check.txt
select count(*) from EX2_REGISTRATION_DTLS where upper(PACKAGE_NAME)='$PACKNAME';
spool off
exit;
EOF
    if [ $? -eq 0 ]; then
        if [ `cat $SOURCE_PATH/logs/${FNAM}_packname_check.txt | tr -d ' /n/t'` -eq 1 ]; then
            echo "`date +"%y%m%d-%T"`: ERROR [Duplicate file] same package $packname already exists in database" >> $SFTP_LOG
            exception $SFTP_LOG $1
        else
            echo "`date +"%y%m%d-%T"`: INFO same package not exists in ex2 application" >> $LOG_FILE
        fi
    else
        echo "`date +"%y%m%d-%T"`: ERROR Database connection issue at is_package_exists function" >> $SFTP_LOG
        exception $SFTP_LOG $1
    fi
}

# Function to check if the transfer ID is valid
is_transferid_valid() {
    TRANS_ID=$1
    $ORACLE_HOME/bin/sqlplus -s $DB_USER/$DB_PASS@$ORACLE_SID <<EOF
set heading off
set feedback off
spool $SOURCE_PATH/logs/${FNAM}_transfer_id_check.txt
select count(*) from EX2_TRANSFER_DTLS where TRANSFER_ID='$TRANS_ID' and IS_ACTIVE='A';
spool off
exit;
EOF
    if [ $? -eq 0 ]; then
        if [ `cat $SOURCE_PATH/logs/${FNAM}_transfer_id_check.txt | tr -d ' /n/t'` -eq 0 ]; then
            echo "`date +"%y%m%d-%T"`: ERROR transfer id $TRANS_ID not exists in database" >> $SFTP_LOG
            exception $SFTP_LOG $1
        else
            echo "`date +"%y%m%d-%T"`: INFO transfer id $TRANS_ID exists in database" >> $LOG_FILE
        fi
    else
        echo "`date +"%y%m%d-%T"`: ERROR DB connection issue at is_transferid_valid function" >> $SFTP_LOG
        exception $SFTP_LOG $1
    fi
}

# Function to check if the previous package is processed
is_prev_processed() {
    COMPOUND=$1
    PROTOCOL=$2
    TRANS_ID=$3
    $ORACLE_HOME/bin/sqlplus -s $DB_USER/$DB_PASS@$ORACLE_SID <<EOF
set heading off
set feedback off
spool $SOURCE_PATH/logs/${FNAM}_previous_pack.txt
select COUNT(*) from EX2_REGISTRATION_DTLS WHERE Registration_Id IN
(SELECT MAX(Registration_Id) FROM EX2_REGISTRATION_DTLS WHERE Compound_Id='$COMPOUND' AND Protocol_No='$PROTOCOL' AND Transfer_Id='$TRANS_ID')
AND STATUS NOT IN('EVALUATED_WITH_ERROR','UPLOADED_TO_CLOUD');
spool off
exit;
EOF
    if [ $? -eq 0 ]; then
        if [ `cat $SOURCE_PATH/logs/${FNAM}_previous_pack.txt | tr -d ' /n/t'` -eq 0 ]; then
            echo "`date +"%y%m%d-%T"`: INFO Previous Package is not exists or processed successfully" >> $LOG_FILE
        else
            echo "`date +"%y%m%d-%T"`: ERROR Previous Package is not processed successfully or archived" >> $SFTP_LOG
            exception $SFTP_LOG $1
        fi
    else
        echo "`date +"%y%m%d-%T"`: ERROR Database connection issue at is_transferid_valid function" >> $SFTP_LOG
        exception $SFTP_LOG $1
    fi
}

# Function to remove log files
rm_internal_log_files() {
    if [[ -f $1 ]]; then
        rm $1
    fi
}

# Function to handle exceptions
exception() {
    /bin/echo "End Time:" `date` | tee -a $1
    /bin/echo "-----------------------------------------------------------------------------------------------------------------------------------" | tee -a $1
    echo "Hi Team,${NL}${NL} Inbound to ex2 file transfer script failed. Please find the attached log file for details.${NL}${NL}Regards,${NL}EX2team" | mailx -r $SUPPORT_EMAIL -s "Inbound to EX2 Transfer Job In ENV=$2 status- FAILED" -a $1 $SUPPORT_EMAIL
    exit 1
}

# Validate Arguments Passed
if [ $1 != "DEV" ] && [ $1 != "TEST" ] && [ $1 != "UAT" ] && [ $1 != "PROD" ]; then
    /bin/echo $SFTP_LOG_MESSAGE | tee -a $SFTP_LOG
    /bin/echo "ERROR $0: Wrong 1st Argument passed. Must be DEV/TEST/UAT/PROD" | tee -a $SFTP_LOG
    exception $SFTP_LOG $1
fi

if [ $DIRC = "INBOUND" ]; then
    if [ ! -d "$TARGET_DIR" ]; then
        /bin/echo $SFTP_LOG_MESSAGE | tee -a $SFTP_LOG
        /bin/echo "ERROR $0: Local TARGET DIRECTORY = $TARGET_DIR does not exist" | tee -a $SFTP_LOG
        exception $SFTP_LOG $1
    fi
    /bin/echo "cd $SOURCE_DIR" > $SFTP_COMMAND_LIST
    echo $SFTP_COMMAND_LIST
    echo $CLOUD_USER@$TGT_SERVER
    sftp -oPort=$PORT -b $SFTP_COMMAND_LIST "$CLOUD_USER@$TGT_SERVER" > /dev/null
    if [ $? = 0 ]; then
        /bin/echo "Source Directory in Cloud Exists" > /dev/null
        rm_internal_log_files $SFTP_COMMAND_LIST
    else
        /bin/echo $SFTP_LOG_MESSAGE | tee -a $SFTP_LOG
        /bin/echo "ERROR $0: Remote SOURCE DIRECTORY = $SOURCE_DIR does not exist" | tee -a $SFTP_LOG
        rm_internal_log_files $SFTP_COMMAND_LIST
        exception $SFTP_LOG $1
    fi
fi

# Updates the initial log
print_log_info $LOG_FILE

/bin/echo "Reading Filename from Cloud" > /dev/null
/bin/echo "ls -l $SOURCE_DIR" > $SFTP_COMMAND_LIST
FILENAME=""

sftp -oPort=$PORT -b $SFTP_COMMAND_LIST "$CLOUD_USER@$TGT_SERVER" > $SOURCE_PATH/logs/${FNAM}_readfile.txt

# Extract filenames from the file and checks the required pattern
while read line; do
    DIRC=`echo $line | awk '{print $1}'`
    if [[ $DIRC = "INBOUND" ]]; then
        FILENAME=`echo $line | awk '{print $9}'`
    fi
done < $SOURCE_PATH/logs/${FNAM}_readfile.txt

rm_internal_log_files $SFTP_COMMAND_LIST

# Validating if filename pattern is correct or not
export FILE_NM_PATERN='[A-Z0-9._%+-]+\.[A-Z0-9.-]+\.[0-9]+\.[A-Z]+.zip'

if [[ $FILENAME != $FILE_NM_PATERN ]]; then
    /bin/echo $SFTP_LOG_MESSAGE | tee -a $SFTP_LOG
    /bin/echo "ERROR $0: Wrong File pattern exists in Source directory. File Name must match ${FILE_NM_PATERN}" | tee -a $SFTP_LOG
    exception $SFTP_LOG $1
else
    echo "File name matched the pattern"
fi

# Extracting variables from the file name
compound_id=`echo $FILENAME | cut -d. -f1`
protocol_no=`echo $FILENAME | cut -d. -f2`
version=`echo $FILENAME | cut -d. -f3`
filetype=`echo $FILENAME | cut -d. -f4`

is_package_exists $compound_id
is_transferid_valid $protocol_no
is_prev_processed $compound_id $protocol_no $version

# Moving files
/bin/echo "get $SOURCE_DIR/$FILENAME" > $SFTP_COMMAND_LIST
sftp -oPort=$PORT -b $SFTP_COMMAND_LIST "$CLOUD_USER@$TGT_SERVER" > /dev/null
if [ $? -eq 0 ]; then
    rm_internal_log_files $SFTP_COMMAND_LIST
else
    /bin/echo $SFTP_LOG_MESSAGE | tee -a $SFTP_LOG
    /bin/echo "ERROR $0: File transfer from Cloud failed" | tee -a $SFTP_LOG
    rm_internal_log_files $SFTP_COMMAND_LIST
    exception $SFTP_LOG $1
fi

/bin/echo "bye" >> $SFTP_COMMAND_LIST

/bin/echo "put $SOURCE_DIR/$FILENAME" > $SFTP_COMMAND_LIST
sftp -oPort=$PORT -b $SFTP_COMMAND_LIST "$CLOUD_USER@$TGT_SERVER" > /dev/null
if [ $? -eq 0 ]; then
    rm_internal_log_files $SFTP_COMMAND_LIST
else
    /bin/echo $SFTP_LOG_MESSAGE | tee -a $SFTP_LOG
    /bin/echo "ERROR $0: File transfer to Cloud failed" | tee -a $SFTP_LOG
    rm_internal_log_files $SFTP_COMMAND_LIST
    exception $SFTP_LOG $1
fi

echo "File transfer from inbound to EX2 completed"
echo "Hi Team,${NL}${NL} Inbound to ex2 file transfer script ran successfully. Please find the attached log file for details.${NL}${NL}Regards,${NL}EX2team" | mailx -r $SUPPORT_EMAIL -s "Inbound to EX2 Transfer Job In ENV=$2 status- SUCCESS" -a $1 $SUPPORT_EMAIL
exit 0