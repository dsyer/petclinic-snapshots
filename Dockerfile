FROM cloudfoundry/run:base

RUN apt-get update
RUN apt-get install -y qemu

COPY buildroot/output/images/bzImage /
COPY buildroot/output/images/rootfs.qcow /rootfs.qcow

ENTRYPOINT [ "qemu-system-x86_64", "-M", "pc-i440fx-2.8", "-enable-kvm", "-m", "2048", "-kernel", "bzImage", "-drive", "file=rootfs.qcow,if=virtio,format=qcow2", "-append", "rootwait root=/dev/vda console=ttyS0", "-net", "nic,model=virtio", "-net", "user,hostfwd=tcp::8080-:8080", "-loadvm", "petclinic", "-nographic", "-sandbox", "on,elevateprivileges=deny,spawn=deny" ]
