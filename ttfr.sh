#!/bin/bash

start_time="$(date -u +%s.%N)"
if ! [ "-d" == "$1" ]; then
    # not docker
    docker=false
    snapshot_name=${1:-petclinic}
    disk_name=${2:-rootfs.qcow}
    if qemu-img snapshot -l output/images/${disk_name} | grep ${snapshot_name}; then
        snapshot="-loadvm ${snapshot_name}"
    fi
    echo Running VM
    qemu-system-x86_64 -M pc-i440fx-bionic -m 2048 -kernel output/images/bzImage -drive file=output/images/${disk_name},if=virtio,format=qcow2 -append "rootwait root=/dev/vda" -net nic,model=virtio -net user,hostfwd=tcp::2222-:22,hostfwd=tcp::8080-:8080 -enable-kvm $snapshot &
else
    docker=true
    shift
    container_name=${1:-petclinic}
    container_image=${2:-dsyer/petclinic}
    if ! docker ps -a --format '{{.Names}}' | grep ${container_name}; then
        echo Running docker container
        docker run --name ${container_name} -p 8080:8080 --privileged ${container_image} &
    fi
    docker start ${container_name}
fi

while ! curl -s localhost:8080 2>&1 > /dev/null; do
	sleep 0.01
done
end_time="$(date -u +%s.%N)"
curl -s -w '\n' localhost:8080
elapsed="$(bc <<< $end_time-$start_time)"
echo "Total of $elapsed seconds elapsed for process"

if [ "${docker}" == "false" ]; then
    pkill qemu
else
    # docker kill ${snapshot_name}
    docker stop ${container_name}
fi
