#!/usr/bin/env bash

set -e

root=`dirname $(readlink -f ${0})`
image=${1:-localhost:5000/dsyer/snapshot}

cd $root

if ! [ -e src/overlay ]; then
    echo Cannot find overlay. Are you in the right directory?
    exit 2
fi

if ! [ -d buildroot ]; then
    mkdir -p buildroot
    (cd buildroot; curl -L https://github.com/buildroot/buildroot/tarball/master | tar -zxf - --strip-components=1)
fi

if ! [ -d petclinic ]; then
    mkdir -p petclinic
    (cd petclinic; curl -L https://github.com/spring-projects/spring-petclinic/tarball/master | tar -zxf - --strip-components=1; ./mvnw package -DskipTests)
fi

cp src/.config buildroot
cp -rf src/overlay buildroot
if ! [ -f buildroot/overlay/root/petclinic.jar ]; then
    cp petclinic/target/*.jar buildroot/overlay/root/petclinic.jar
fi

if ! [ -f buildroot/output/images/rootfs.ext2 ]; then
    if ! [ `id -u` == "1000" ]; then
        echo Not running as user uid=1000. Aborting.
        exit 3
    fi
    # This works if you run as user uid=1000
    docker run -v `pwd`/buildroot:/home/br-user/buildroot -w /home/br-user/buildroot buildroot/base make
fi

if ! [ -f buildroot/output/images/rootfs.qcow ]; then
    (cd buildroot/output/images/;  qemu-img convert -O qcow2 rootfs.ext2 rootfs.qcow)
fi

(cd buildroot/output/images; qemu-system-x86_64 -M pc-i440fx-2.8 -enable-kvm -m 2048 -kernel bzImage \
    -drive file=rootfs.qcow,if=virtio,format=qcow2 -append 'rootwait root=/dev/vda console=ttyS0' \
    -net nic,model=virtio -net user,hostfwd=tcp::8080-:8080 \
    -nographic -monitor telnet::45454,server,nowait) &

while ! curl -s localhost:8080 2>&1 > /dev/null; do
	sleep 0.01
done

# Take a snapshot
(echo savevm petclinic; sleep 2; echo quit) | nc localhost 45454

docker build -t $image .