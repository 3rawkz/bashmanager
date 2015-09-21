#!/bin/bash





############################################################
# BASH MANAGER 1.01 - 2015-09-10
# By LingTalfi 
############################################################
major=${BASH_VERSION:0:1}
if [ $major -lt 4 ]; then
    echo "This programs requires a minimum verson of bash 4 (your version is $BASH_VERSION)"
    exit 1
fi

############################################################
# ERROR POLICY IN A NUTSHELL
############################################################
# 
# In short, my advice for task creators: should you use error or warning?
#       -> Use error if something that the maintainer wouldn't expect occurs
#       -> User warning for yourself while debugging your own task 
# 
# 
# The script (and probably any script by the way) has three possible issues:
# 
# - success
# - failure
# - sucess with recoverable failures
#
# In case of success, there is not much to say.
# In case of failure, the error message is sent to STDERR.
# In case of recoverable failures, the message is also sent to 
# STDERR (because the admin should be able to see it), but 
#       we also ask this question: 
#       should we continue the script anyway or exit?
#       The answer depends on the user, so we provide the
#       STRICT_MODE variable for that, which can take one of
#       two values:
#           0 (default): the script will always try to continue 
#                   if possible.
#           1: the script exits when the first error is encountered.
# 
# Failure and recoverable failures are handled by the error function.
#
# At our disposal, we have the following functions:
#   - log           (outputs to STDOUT, only if VERBOSE=1)
#   - warning       (outputs to STDOUT in orange)
#   - error         (failure, recoverable failure)
#  
# The log function displays a message only if VERBOSE=1.
# By default, VERBOSE=0.
# The user can set VERBOSE=1 by using the -v option on the command line.
#
# The warning is like the log, but the text is orange.
# However, the warning always shows up, without respect to the VERBOSE option.
# 
# The error method sends a message to STDERR.
# Also, if STRICT_MODE=1, the script will stop immediately.
# By default, STRICT_MODE=0.
# The user can set STRICT_MODE=0 by using the -s option on the command line.
# 
# 
############################################################

############################################################
# internal variables, please do not modify
############################################################
RETURN_CODE=0  
ERROR_CODE=1
VERBOSE=0   # make the log function output something
STRICT_MODE=0   # if 1, the script exits when an error is triggered
CONFIG_FILES=()
TASKS_LIST=()
TASKS_LIST_OPTIONS=()
TASKS_NAMES=()      # per config file 
PROJECTS_LIST=()
PROJECTS_LIST_OPTIONS=()
PROJECTS_NAMES=()      # per config file 
declare -A _CONFIG      # this contains the values from config.defaults, should never be touched
declare -A CONFIG       # every time a project is called, the CONFIG array is recreated: it's a copy of _CONFIG. 
                        # tasks can then update the CONFIG array in the scope of one project.  
                        # For instance, it is used by the depositories.sh task in order to allow the user to
                        # choose a depository per project from the config file.
declare -A VALUES       # concerned task's values
declare -A ALL_VALUES # other tasks' values, namespaced with the format taskName_key (instead of key)
declare -A OTHER_VALUES  # other project's values
declare -A CONFIG_OPTIONS  # config options set via the command line options


COLOR_TASK='\033[1m'
COLOR_IMPORTANT='\033[0;44;33m'
COLOR_WARNING='\033[0;31m'
COLOR_STOP='\033[0m' 

COL_IMPORTANT=$(echo -e "${COLOR_IMPORTANT}")
COL_WARNING=$(echo -e "${COLOR_WARNING}")
COL_STOP=$(echo -e "${COLOR_STOP}")



#----------------------------------------
# config.defaults (and command line) specials
#       They all begin with an underscore
#----------------------------------------
_program_name="bash manager"




############################################################
# Functions
############################################################


#----------------------------------------
# Use this function to split a string with delimiters.
#----------------------------------------
# Splits the string with the given delimiter.
# The results are put in the SPLITLINE_ARR array.
# The delimiter is a string of length 1.
# 
# There are two different cases:
# 
# - if the delimiter is the first char of string:
#           then the keys of the SPLITLINE_ARR will
#           be those passed to the function (argNameN, ...)
#           and the function returns 1.
# 
# - if the delimiter is not the first char of string,
#          the SPLITLINE_ARR is empty and the function 
#           returns 0. 
# 

declare -A SPLITLINE_ARR
splitLine () # ( string, delimiter [, argNameN ]* )
{
    unset SPLITLINE_ARR
    declare -gA SPLITLINE_ARR=[]
    string="$1"
    delimiter="$2"
    if [ "$delimiter" = "${string:0:1}" ]; then
        string="${string:1}"
        shift
        shift
        key="$1"
        local i
        i=1
        while [ -n "$key" ]; do
            key="$1"
            if [ -n "$key" ]; then
                value=$(echo "$string" | cut -d"${delimiter}" -f${i} | xargs)
                SPLITLINE_ARR["$key"]="$value"
                (( i++ ))
                shift
            fi
        done
        return 1;
        
    else
        SPLITLINE_ARR["_default"]="$string"
        return 0;
    fi
    
}





# Utils
error () # ( message )
{
    echo -e "$_program_name: error: $1" >&2
    RETURN_CODE=$ERROR_CODE
    
    if [ 1 -eq $VERBOSE ]; then
        printTrace    
    fi
    
    if [ 1 -eq $STRICT_MODE ]; then
        exit 1
    fi
}



warning () # ( message)
{
    old=$VERBOSE
    VERBOSE=1
    log "$1" "1"
    VERBOSE=$old
}

confError () # ()
{
    error "Bad config: $1"
}

abort (){
    error "Aborting..."
    exit "$ERROR_CODE"
}


# level=0 means no special color
# level=1 means warning color
# level=2 means important color
log () # (message, level=0)
{
    if [ 1 -eq $VERBOSE ]; then
        if [ -z "$2" ]; then
            echo -e "$1" | sed "s/^/$_program_name\(v\): /g"
        else
            if [ "1" = "$2" ]; then
                echo -e "$1" | sed -e "s/^.*$/${_program_name}\(v\): ${COL_WARNING}&${COL_STOP}/g"
            elif [ "2" = "$2" ]; then
                echo -e "$1" | sed -e "s/^.*$/${_program_name}\(v\): ${COL_IMPORTANT}&${COL_STOP}/g"
            fi
        fi
    fi
}




# outputs a list of elements of separated by a sep 
toList ()# ( arrayEls, ?sep ) 
{
    sep="${2:-, }"
    arr=("${!1}")
    i=0
    for path in "${arr[@]}"; do
        if [ $i -eq 1 ]; then
            echo -n "$sep"
        fi
        echo -n "$path"
        i=1
    done
    echo 
}


# same as toList, but prints a header first 
printList ()# ( header, arrayEls, ?sep=", " ) 
{
    echo -n "$1"
    sep=${3:-, }
    toList "$2" "$sep"
}

printAssocArray ()# ( assocArrayName ) 
{
    var=$(declare -p "$1")
    eval "declare -A _arr="${var#*=}
    for k in "${!_arr[@]}"; do
        echo "$k: ${_arr[$k]}"
    done
    
}

# outputs an array as a stack beginning by a leading expression 
toStack ()# ( arrayEls, ?leader="-- ") 
{
    lead="${2:--- }"
    arr=("${!1}")
    echo 
    for path in "${arr[@]}"; do
        echo "$lead$path"
    done
}


# same as toStack, but prints a header first 
printStack ()# ( header, arrayEls, ?leader="-- " ) 
{
    echo -n "$1"
    lead=${3:--- }
    toStack "$2" "$lead"
}

printStackOrList ()
{
    name=("${!2}")
    len="${#name[@]}"
    if [ $len -gt 2 ]; then
        printStack "$1" "$2" 
    else
        third=${3:-, }
        printList "$1" "$2"
    fi
}

# This method should print ---non blank and comments stripped--- lines of the given config file
printConfigLines ()
{
   while read line || [ -n "$line" ]; do
        
        # strip comments
        line=$(echo "$line" | cut -d# -f1 )
        if [ -n "$line" ]; then
            echo "$line"
        fi
   done < "$1"    
}

# Store the key and values found in configFile into the array which arrayEls is given
collectConfig ()#( arrayName, configFile )
{
    arr=("$1")
    while read line
    do
        key=$(echo "$line" | cut -d= -f1 )
        value=$(echo "$line" | cut -d= -f2- )        
        if [ ${#value} -gt 0 ]; then
            arr["$key"]="$value"            
        fi
    done < <(printConfigLines "$2")    
}



dumpAssoc ()# ( arrayName ) 
{
    title="${1^^}"
    echo 
    echo "======= $title ========"
    printAssocArray "$1"
    echo "======================"
    echo       
}


parseAllValues ()# ( configFile ) 
{
    configFile="$1"
    namespace=""
    lineno=1
    while read line || [ -n "$line" ]; do
        if [ -n "$line" ]; then
            line="$(echo $line | xargs)" # trimming
            
            # strip comments: lines which first char is a sharp (#)
            if ! [ '#' = "${line:0:1}" ]; then
                if [[ "$line" == *"="* ]]; then
                    if [ -n "$namespace" ]; then
                        key=$(echo "$line" | cut -d= -f1 )
                        value=$(echo "$line" | cut -d= -f2- )
                        ALL_VALUES["${namespace}_${key}"]="$value"
                        
                        inArray "$key" "${PROJECTS_NAMES[@]}"
                        if [ 1 -eq $?  ]; then
                            PROJECTS_NAMES+=("$key")
                            log "Project found: $key"
                        fi 
                        
                    else
                        warning "No namespace found for the first lines of file $configFile"
                    fi
                else
                    # if the last char is colon (:) and the line doesn't contain an equal symbol(=) 
                    # then it defines a new namespace
                    if [ ":" = "${line:${#line}-1:${#line}}" ]; then
                        namespace="${line:0:${#line}-1}" 
                        log "Namespace found: $namespace"
                        TASKS_NAMES+=("$namespace")
                    else
                        error "Unknown line type in file $configFile, line $lineno: ignoring"
                    fi
                fi 
            fi
        fi
        (( lineno++ ))
    done < "$configFile"    
}



# We can use this function to do one of the following:
# -- check if an associative array has a certain key            inArray "myKey" "${!myArray[@]}" 
# -- check if an associative array contains a certain value     inArray "myValue" "${myArray[@]}"
inArray () # ( value, arrayKeysOrValues ) 
{
  local e
  for e in "${@:2}"; do 
    [[ "$e" == "$1" ]] && return 0; 
  done
  return 1
}


printTrace() # ( commandName?, exit=0? ) 
{
    
    m=""
    m+="Trace:\n"
    m+="----------------------\n"
    local frame=0
    last=0
    while [ 0 -eq $last ]; do
        line="$( caller $frame )"
        last=$?
        ((frame++))
        if [ 0 -eq $last ]; then
            m+=$(echo "$line" | awk '{printf "function " $2 " in file " $3 ", line " $1 "\n" }')
            m+="\n"
        fi
    done
    echo -e "$m"
}


startTask () #( taskName )
{
    log "${COLOR_TASK}---- TASK: $1 ------------${COLOR_STOP}"
}

endTask ()#( taskName )
{
    log "${COLOR_TASK}---- ENDTASK: $1 ------------${COLOR_STOP}"
}



printDate ()
{
    echo $(date +"%Y-%m-%d__%H-%M")
}

# used by chronos scripts
printCurrentTime ()
{
    echo $(date +"%Y-%m-%d  %H:%M:%S")
}



# This function will export the CONFIG array for other scripting 
# languages, like php or python for instance.
# variables are exported using the following format:
# BASH_MANAGER_CONFIG_$KEY

exportConfig ()# ()
{
    local KEY
    for key in "${!CONFIG[@]}"; do
        KEY=$(echo "$key" | tr '[:lower:]' '[:upper:]')
        export "BASH_MANAGER_CONFIG_${KEY}"="${CONFIG[$key]}"
    done
}

# This function work in pair with exportConfig.
# What it does is process the output of a script coded in 
# another scripting language (php, python, perl...).
# Such a script is called "foreign" script
# There is a convention for those foreign scripts to be aware of:
#       - Every line should end with the carriage return
#       - a line starting with
#                       log:
#               will be send to the bash manager log
# 
#       - foreign scripts can update the content of the CONFIG array.
#               a line with the following format:
#               BASH_MANAGER_CONFIG_$KEY=$VALUE

#               will add the key $KEY with value $VALUE to the
#               CONFIG array. 
# 
                    
                    
processScriptOutput () # ( vars )
{
    local isConf
    while read line
    do
        if [ "log:" = "${line:0:4}" ]; then
            log "${line:4}"
        elif [ "warning:" = "${line:0:8}" ]; then
            warning "${line:8}"
        elif [ "error:" = "${line:0:6}" ]; then
            error "${line:6}"
        elif [ "exit:" = "${line:0:5}" ]; then
            exit $(echo "$line" | cut -d: -f2)
        else
            isConf=0
            if [ "BASH_MANAGER_CONFIG_" = "${line:0:20}" ]; then
                if [[ "$line" == *"="* ]]; then 
                    value=$(echo "$line" | cut -d= -f2- )
                    key=$(echo "$line" | cut -d= -f1 )
                    key="${key:20}"
                    CONFIG["$key"]="$value"
                    isConf=1
                fi
            fi
            if [ 0 -eq $isConf ]; then
                echo "$line"
            fi
        fi 
    done <<< "$1"
}


printRealTaskName () # ( taskString )
{
    echo "$1" | cut -d'(' -f1
}

printRealTaskExtension () # ( taskString )
{
    extension=sh
    ext=$(echo "$1" | cut -d'(' -s -f2)
    if [ -n "$ext" ]; then
        if [ ')' = "${ext:${#ext}-1:${#ext}}" ]; then
            echo "${ext:0:${#ext}-1}"
            return 0
        fi
    fi
    echo "$extension"
}

############################################################
# MAIN SCRIPT
############################################################


#----------------------------------------
# Processing command line options
#----------------------------------------
while :; do
    key="$1"
    case "$key" in
        --option-*=*)
            optionName=$(echo "$1" | cut -d= -f1)
            optionValue=$(echo "$1" | cut -d= -f2-)
            optionName="${optionName:9}"
            CONFIG_OPTIONS["$optionName"]="$optionValue"
            ;;
        -c) 
            CONFIG_FILES+=("$2")
            shift 
        ;;
        -h) 
            _home=("$2")
            shift 
        ;;
        -p) 
            PROJECTS_LIST_OPTIONS+=("$2")
            shift 
        ;;
        -s) 
            STRICT_MODE=1
        ;;
        -t) 
            TASKS_LIST_OPTIONS+=("$2")
            shift 
        ;;
        -v) 
            VERBOSE=1
        ;;
        *)  
            break
        ;;
    esac
    shift
done


#----------------------------------------
# bash manager requires that the _home variable
# is defined, either from the caller script, or with the command line options -h
#----------------------------------------
if [ -z "$_home" ]; then
    error "variable _home not defined, you can set it via the -h option, or create a wrapper script which defines _home and sources this bash manager script"
    exit $ERROR_CODE
fi
cd "$_home"
# resolve relative paths
_home=$("pwd")


#----------------------------------------
# Check the basic structure
# - home path
# ----- config.defaults 
# ----- config.d
# ----- tasks.d
#----------------------------------------
# Turning _home as an absolute path
log "HOME is set to: $_home"

configDefaults="$_home/config.defaults"
configDir="$_home/config.d"
tasksDir="$_home/tasks.d"

if ! [ -f "$configDefaults" ]; then
    confError "Cannot find config.defaults file, check your _home variable (not found: $configDefaults)"

elif ! [ -d "$configDir" ]; then
    confError "Cannot find config.d directory, check your _home variable (not found: $configDir)"
elif ! [ -d "$tasksDir" ]; then
    confError "Cannot find tasks.d directory, check your _home variable (not found: $tasksDir)"
fi
[ $RETURN_CODE -eq 1 ] && abort





#----------------------------------------
# Prepare _CONFIG from config.defaults
#----------------------------------------
while read line
do
    key=$(echo "$line" | cut -d= -f1 )
    value=$(echo "$line" | cut -d= -f2- )        
    if [ ${#value} -gt 0 ]; then
        _CONFIG["$key"]="$value"            
    fi
done < <(printConfigLines "$configDefaults")


for key in "${!CONFIG_OPTIONS[@]}"; do
    _CONFIG["$key"]="${CONFIG_OPTIONS[$key]}"
done

# we will add a special _HOME value for the tasks
_CONFIG[_HOME]="$_home"





#----------------------------------------
# Collecting configuration files.
# If the user doesn't specify config files on the command line,
# we use all the config files located in the HOME/config.d directory
#----------------------------------------
cd "$configDir"
if [ -z $CONFIG_FILES ]; then
    CONFIG_FILES=($(find . | grep '\.txt$'))
else
    for i in "${!CONFIG_FILES[@]}"; do
        CONFIG_FILES[$i]="./${CONFIG_FILES[$i]}.txt"
    done
fi



#----------------------------------------
# Outputting some info on STDOUT
#----------------------------------------
log "$(printStack 'Collecting config files: ' CONFIG_FILES[@])"
if [ -z $TASKS_LIST_OPTIONS ]; then
    log "Collecting tasks: (all)"
else        
    log "$(printStack 'Collecting tasks: ' TASKS_LIST_OPTIONS[@])"
fi
if [ -z $PROJECTS_LIST_OPTIONS ]; then
    log "Collecting projects: (all)"
else        
    log "$(printStack 'Collecting projects: ' PROJECTS_LIST_OPTIONS[@])"
fi








#----------------------------------------
# Spread special internal variables
#----------------------------------------
if [ -n "${_CONFIG[_program_name]}" ]; then
    _program_name="${_CONFIG[_program_name]}"
fi




#----------------------------------------
# Processing all config files found, one after another.
#----------------------------------------
cd "$configDir"
for configFile in "${CONFIG_FILES[@]}"; do
    if [ -f "$configFile" ]; then
        log "Scanning config file $configFile"
        
        unset VALUES
        unset ALL_VALUES
        
        declare -A VALUES
        declare -A ALL_VALUES
        
        
        unset TASKS_NAMES
        TASKS_NAMES=()
        unset PROJECTS_NAMES
        PROJECTS_NAMES=()
        unset PROJECTS_LIST
        PROJECTS_LIST=()
        unset TASKS_LIST
        TASKS_LIST=()                  
   
        
        # For every config file, 
        # we collect the following arrays:
        # - PROJECT_NAMES: all the projects found in the current config file (no duplicate), in order of appearance
        # - TASKS_NAME: all the tasks found in the current config file (no duplicate), in order of appearance
        # - ALL_VALUES, an array that contains all the values we found, and looks like this:
        #       ALL_VALUES[task_project]=value
        #       ALL_VALUES[task_project2]=value
        #       ALL_VALUES[task2_project]=value
        #       ...
        #       ...
        # 
        parseAllValues "$configFile"
        
        
        # Preparing TASKS_LIST
        # If no task is defined,
        # we use all tasks found in TASKS_NAME
        if [ 0 -eq ${#TASKS_LIST_OPTIONS[@]} ]; then
            for task in "${TASKS_NAMES[@]}"; do
                TASKS_LIST+=("$task")
            done
        else
            for task in "${TASKS_LIST_OPTIONS[@]}"; do
                TASKS_LIST+=("$task")
            done              
        fi    
#        dumpAssoc "TASKS_NAMES"
#        dumpAssoc "TASKS_LIST"
        
        
        # Preparing PROJECTS_LIST_OPTIONS
        # If no task is defined,
        # we use all tasks found in TASKS_NAME        
        if [ 0 -eq ${#PROJECTS_LIST_OPTIONS[@]} ]; then
            for project in "${PROJECTS_NAMES[@]}"; do
                PROJECTS_LIST+=("$project")
            done
        else    
            for project in "${PROJECTS_LIST_OPTIONS[@]}"; do
                PROJECTS_LIST+=("$project")
            done             
        fi       
#        dumpAssoc "PROJECTS_LIST"
        
        
        
        # processing the projects
        for project in "${PROJECTS_LIST[@]}"; do
        
            log "Processing project $project" "2"
            
            
            unset CONFIG
            unset OTHER_VALUES
            declare -A CONFIG
            declare -A OTHER_VALUES
            
            
            # creating a CONFIG copy for the tasks to use 
            for key in "${!_CONFIG[@]}"; do
                CONFIG["$key"]="${_CONFIG[$key]}" 
            done
#            dumpAssoc "CONFIG"
            
            
            # preparing other values for this project
            plen=${#project}
            (( plen++ ))  # add the underscore length
            for key in "${!ALL_VALUES[@]}"; do
                if [ "_$project" = "${key:${#key}-$plen}" ]; then
                    ptask="${key:0:${#key}-$plen}"
                    OTHER_VALUES["$ptask"]="${ALL_VALUES[$key]}"
                fi 
            done
#            dumpAssoc "OTHER_VALUES"
            
            
            
            for task in "${TASKS_LIST[@]}"; do
            
                # Tasks which name begins with underscore are skipped
                # This is handy for quick testing
                if ! [ "_" = "${task:0:1}" ]; then
            
            
                    # handling foreign script direct call
                    # notation is: 
                    #       taskName(extension)
                    #       
                    #       
                    realTaskExtension=$(printRealTaskExtension "$task")
                    realTask=$(printRealTaskName "$task")
                    
                    
                    
            
            
                    taskScript="$tasksDir/$realTask.${realTaskExtension}"
                    if [ -f "$taskScript" ]; then
                        
                            # Prepare the values to pass to the script
                                                 
                            key="${task}_${project}"
                            
                            inArray "$key" "${!ALL_VALUES[@]}"
                            if [ 0 -eq $? ]; then
                                VALUE="${ALL_VALUES[$key]}"
                                
                                
                                CONFIG[_VALUE]="$VALUE"
                                
                                
                                log "Running task $task ($taskScript)"
                                
                                
                                
                                if [ "sh" = "$realTaskExtension" ]; then
                                    . "$taskScript"
                                else
                                    # running foreign script
                                    isHandled=1
                                    exportConfig
                                    case "$realTaskExtension" in
                                        php)
                                            __vars=$(php -f "$taskScript")
                                        ;;
                                        py)
                                            __vars=$(python "$taskScript")
                                        ;;
                                        rb)
                                            __vars=$(ruby "$taskScript")
                                        ;;
                                        pl)
                                            __vars=$(perl "$taskScript")
                                        ;;
                                        *)
                                            error "The $realTaskExtension extension is not handled. Email me if you think it should be."
                                            isHandled=0
                                        ;;
                                    esac
                                    
                                    if [ 1 -eq $isHandled ]; then
                                        processScriptOutput "$__vars"
                                    fi
                                fi                                
                            fi
                            
                            
                    else
                        error "Script not found: $taskScript"
                    fi
                else
                    log "skipping task ${task} by the underscore convention"
                fi
            done
            
        done
    else
        error "Config file not found: $configFile"
    fi
done









exit $RETURN_CODE

