#!/bin/bash

# Absolute or relative path to the user defined scripts. It is usually the script directory.
: "${scripts_dir:=.}"


version=1.5
app_name="Docker Events Handler"

# ==================  Options bellow usually don't need to be changed ==============

# systemd service file name
servicefile=/etc/systemd/system/docker-events-handler.service

# Main script will be copied to this path and name.
maindir=/usr/lib/docker-events-handler
mainfile=docker_events.sh

# char used for split label docker-events.route to separated routes.
splitter=";"

# =======================   END OF Options  ======================

# Check that dependics are availble
dependics="realpath id nsenter docker"
for dep in $dependics; do
        command -v $dep >/dev/null 2>&1 || { echo >&2 "Error! '$dep' is not installed. Aborting."; exit 1; }
done

error=0  # Set to 1 if was error

self=$(realpath $0)
cd $(dirname $0)
base=$(pwd)

# define Usage
usage() {
echo "
$app_name, v$version

Usage: $0 -c client_name [--install] [--service] [--version]
    --install   : Install itself as a service
    --service   : Service mode. For internal use.
    -h, --help  : show this help
    --version   : show app version 
"
}

# This function handle the system service
service() {
    # try to detect our own contaner name
    selfconame=$(basename $(docker inspect $(cat /etc/hostname)  --format '{{ index .Name }}' 2>/dev/null))
    
    # In case docker was stopped we will continue to try read it events in endless loop
    while true; do
        docker events --filter type=container --filter event=start --format '{{.Status}}.{{.Actor.Attributes.name}}' --since=15s | while read name; do

            echo Event has been catched: $name

            # check for container labels fist
            coname=$(echo $name | cut -d. -f2)
            
            # skip ourself events
            [[ "$coname" == "$selfconame" ]] && continue

            # getting IP address labels
            values=$(docker inspect $coname --format '{{ index .Config.Labels "docker-events.address" }}')
            
            if [ ! -z "$values" ]; then
                coPID=$(docker inspect --format {{.State.Pid}} $coname)

                IFS=$splitter
                for val in $values; do
                    echo "$coname: Found container assigned ip-address-label and applying it: $val"
                    cmd="nsenter -n -t $coPID ip address $val"
                    sh -c "$cmd"
                done
            fi

            # getting route labels
            values=$(docker inspect $coname --format '{{ index .Config.Labels "docker-events.route" }}')
            
            if [ ! -z "$values" ]; then
                coPID=$(docker inspect --format {{.State.Pid}} $coname)

                IFS=$splitter
                for routestr in $values; do
                    echo "$coname: Found container assigned route-label and applying it: $routestr"
                    cmd="nsenter -n -t $coPID ip route $routestr"
                    sh -c "$cmd"
                done
            fi

            # getting rules labels
            values=$(docker inspect $coname --format '{{ index .Config.Labels "docker-events.rule" }}')
            
            if [ ! -z "$values" ]; then
                coPID=$(docker inspect --format {{.State.Pid}} $coname)

                IFS=$splitter
                for routestr in $values; do
                    echo "$coname: Found container assigned rule-label and applying it: $routestr"
                    cmd="nsenter -n -t $coPID ip rule $routestr"
                    sh -c "$cmd"
                done
            fi

            # getting host route labels 
            values=$(docker inspect $coname --format '{{ index .Config.Labels "docker-events.host-route" }}')
            if [ ! -z "$values" ]; then
                if [ -z $in_docker ]; then
                    IFS=$splitter
                    for routestr in $values; do
                        echo "$coname: Found container assigned host-route-label and applying it: $routestr"
                        cmd="ip route $routestr"
                        sh -c "$cmd"
                    done
                else
                    echo "Error! $coname: host-route-label is not supported if Docker Event Handler running in the container"
                fi
            fi

            # check for user defined scripts
            # Scripts must be executables and named: event.name
            if [ -f $scripts_dir/$name ]; then
                echo "$coname: Found and running event handler: $scripts_dir/$name"
                $scripts_dir/$name
            else
                echo "Event handler was not found and skipped: $scripts_dir/$name"
            fi
        done
        sleep 5
    done
}   
# END OF service()


# Install the service and exit
install() {

echo "Installing service file ($servicefile)..."
echo "
[Unit]
Description=Docker Event Handler Service
After=docker.service

[Service]
# For old version systemd Type it must be exec
#Type=exec
Type=simple

ExecStart=$maindir/$mainfile --service

Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
" >$servicefile || error=1

echo "Installing main script file ($maindir/$mainfile)..."
mkdir -p $maindir           || error=1
cp $self $maindir/$mainfile || error=1

[[ $error == 1 ]] && echo "Error(s) occured. Aborted." && exit 1

systemctl daemon-reload 
echo "Enable docker-events-handler service...."
systemctl enable docker-events-handler
cd $maindir

echo "
Installation complete! 
User defined scripts path: 
   $(realpath $scripts_dir)

Start service: 
    systemctl start docker-events-handler

Show logs: 
    journalctl -u docker-events-handler

"
}
# END OF install()

exit_function() {
    echo "Exiting by external signal..."
    exit
}
# ====================== Main Code section ============================

# Check arguments
[[ $# == 0 ]] && usage && exit 1

doinstall=false
doservice=false

while [[ "$#" -gt 0 ]]; do case $1 in
  --version)  echo $version; exit;;
  --install) doinstall=true;;
  --service) doservice=true;;
  *) echo "Unknown parameter passed: $1"; usage; exit 1;;
esac; shift; done


# ======================= check for root ================================
[[ $(id -u) -ne 0 ]] && echo "Must be run as root! Aborted." &&  exit 1

echo $app_name, v$version
echo Scripts Directory: $(realpath $scripts_dir)

$doinstall && install && exit
trap "exit_function" SIGINT SIGTERM

echo Running events monitor...
$doservice && service && exit

