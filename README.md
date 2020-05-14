
How to run the [Spring Petclinic](https://github.com/spring-projects/spring-petclinic) on Kubernetes with subsecond scale up. The first step is to build a lightweight VM image with [Buildroot](https://github.com/buildroot/buildroot). Then you log in and get the Petclinic running. Then you containerize it, and finally deploy to Kubernetes. Fun fact: if you run with MySQL instead of the default in-memory database, it still works surprisingly well.

TL;DR You can containerize a VM snapshot. It's fast, but not as fast as if you run it on the host. You can start Petclinic in less than half a second on the host, and less than a second in a container. In Kubernetes it feels pretty much instantaneous. The containers have to run `--privileged`.

## Quick Start and Automation

There's a script that builds a container (pre-requisites, `docker`, `qemu`, `qemu-utils`, you have to be running as user `uid=1000`):

```
$ ./build.sh
$ docker run --privileged -p 8080:8080 localhost:5000/dsyer/snapshot
```

The container starts very fast, and serves the PetClinic on port 8080.

## Deploy to Kubernetes

Make a deployment:

```
$ kubectl create deployment petclinic --image localhost:5000/dsyer/snapshot --dry-run -o yaml > deployment.yaml
$ echo --- >> deployment.yaml
$ kubectl create service clusterip petclinic --tcp=80:8080 --dry-run -o yaml >> deployment.yaml
```

and escalate the security context in the container so it can run privileged:

```
apiVersion: apps/v1
kind: Deployment
...
    spec:
      containers:
      - image: localhost:5000/dsyer/snapshot
        name: snapshot
        securityContext:
          privileged: true
```

Then deploy:

```
$ kubectl apply -f deployment.yaml
```

You will see the container start very quickly if you have a dashboard or `kubectl get all` running in another terminal. Scale it up by adding replicas:

```
apiVersion: apps/v1
kind: Deployment
metadata:
  labels:
    app: petclinic
  name: petclinic
spec:
  replicas: 2
...
```

and they start instantly:

```
every 1.0s: kubectl get all                                    tower: Wed May  6 08:13:19 2020

NAME                             READY   STATUS    RESTARTS   AGE
pod/petclinic-86468f4bb7-ph2kb   1/1     Running   0          7m12s
pod/petclinic-86468f4bb7-rfhgt   1/1     Running   0          6s
...
```

## The Gorey Details

Here's how to do it all a bit more manually, giving details at each step and options for how to do things differently.

### Get Buildroot

```
$ mkdir -p buildroot
$ cd buildroot
$ curl -L https://github.com/buildroot/buildroot/tarball/master | tar -zxf - --strip-components=1
```

### Build a VM Image

You can do this on the host if you have the right tools installed (in Ubuntu you need `gcc g++ build-essential libncurses-dev unxip bc`). Or you can open the project in VSCode and `Reopen in Container` to start a container that has all the tools installed, then you can run these commands in a terminal in the IDE:

```
$ make qemu_x86_64_defconfig
$ make menuconfig
```

Configuration options:

* "Toolchain": select `glibc` and `C++` support
* "Target Packages": select `X.Org` from "Graphic libraries..." and `openjdk` from "Interpreter languages...". Add "openssh" from "Networking..." if you want to use ssh or scp to modify the image.
* "Filesystem images": select a larger filesystem image size in and make it an `ext4` filesystem type
* "System configuration": set a root password (optionally) and switch _off_ the `getty` on console (it seems to end up ignoring the root password)

Then:

```
$ make
$ ls output/images/
bzImage  rootfs.ext2 rootfs.ext4
```

Convert the disk to qcow so it supports snapshots:

```
$ cd output/images
$ qemu-img convert -O qcow2 rootfs.ext2 rootfs.qcow
```

Now we can run it on the host:

```
$ qemu-system-x86_64 -M pc-i440fx-2.8 -enable-kvm -m 2048 -kernel bzImage -drive file=rootfs.qcow,if=virtio,format=qcow2 -append 'rootwait root=/dev/vda' -net nic,model=virtio -net user,hostfwd=tcp::2222-:22,hostfwd=tcp::8080-:8080
```

The console comes up and you log in:

```
buildroot login: root
Password:
# java -version
openjdk version "13.0.2" 2020-01-14
OpenJDK Runtime Environment (build 13.0.2+13)
OpenJDK 64-Bit Server VM (build 13.0.2+13, mixed mode)
```

Edit `/etc/ssh/sshd_config` and set

```
PermitRootLogin yes
```

and restart the service (you can `kill -HUP` the `opensshd` process). You can also make that change in the disk image before you run it, if you mount the raw file locally first. Then you should be able to ssh in from the host:

```
$ ssh root@192.168.2.19 -p 2222
root@192.168.2.19's password: 
# java -version
openjdk version "13.0.2" 2020-01-14
OpenJDK Runtime Environment (build 13.0.2+13)
OpenJDK 64-Bit Server VM (build 13.0.2+13, mixed mode)
```

### Run the Petclinic

First download the source code. From the root (where the `README` is):

```
$ mkdir -p petclinic
$ cd petclinic
$ curl -L https://github.com/spring-projects/spring-petclinic | tar -zxf - --strip-components=0
$ ./mvnw package
$ cd ..
```

So now we need to copy in a JAR file that we can run. You could use `scp` and set it up manually, or you can build it into the VM image. Here's how to do the latter:

```
$ cp -rf  overlay buildroot
$ cp petclinic/target/*.jar buildroot/overlay/root/petclinic.jar
$ sed -i -e ',^BR2_ROOTFS_OVERLAY=.*$,BR2_ROOTFS_OVERLAY="./overlay",' buildroot/.config
$ (cd buildroot; make)
$ cd buildroot/output/images
$ qemu-img convert -O qcow2 rootfs.ext2 rootfs.qcow
```

Now run the image again (on the host if you were building in a container):

```
$ qemu-system-x86_64 -M pc-i440fx-2.8 -enable-kvm -m 2048 -kernel bzImage -drive file=rootfs.qcow,if=virtio,format=qcow2 -append 'rootwait root=/dev/vda' -net nic,model=virtio -net user,hostfwd=tcp::2222-:22,hostfwd=tcp::8080-:8080
```

To run without the QEMU GUI:

```
$ qemu-system-x86_64 -M pc-i440fx-2.8 -enable-kvm -m 2048 -kernel bzImage -drive file=rootfs.qcow,if=virtio,format=qcow2 -append 'rootwait root=/dev/vda console=ttys0' -net nic,model=virtio -net user,hostfwd=tcp::2222-:22,hostfwd=tcp::8080-:8080 -nographic
```

If you have issues with permissions, e.g.

```
$ qemu-system-x86_64 ...
Could not access KVM kernel module: Permission denied
failed to initialize KVM: Permission denied
```

then check that you are a member of the `kvm` group and that `/dev/kvm` belongs to that group, e.g.

```
$ sudo chown root:kvm /dev/kvm 
$ sudo usermod -aG kvm br-user
$ newgrp kvm
$ newgrp br-user
```

The petclinic runs in the VM when it starts. It takes about 15 seconds to start, but we constrained the system a lot, so it's not expected to be super quick. If we gave it more memory and cpus it would start much quicker, probably closer to 3 seconds on the host. Warm it up by curling it from the host (try a few times if it fails at first - it might still be starting):

```
$ curl localhost:8080
...
</html>
```

### Take a Snapshot

We can take a snapshot in QEMU GUI (if you are running with `-nographic` then it is `CTRL-A C`):

```
CTRL-ALT-2
(qemu) savevm petclinic
(qemu) quit
```

Then you can start it super fast. The `ttfr.sh` script measures startup time (time to first request):

```
$ ./ttfr.sh
...

</html>
Total of .505384319 seconds elapsed for process
qemu-system-x86_64: terminating on signal 15 from pid 2955613 ()
```

It's slightly slower with 4096M memory, but not much (<10%).

### Containerize the Snapshot

When you have the snaphot you can build it into a container image. Here's a `Dockerfile`:

```
FROM cloudfoundry/run:base

RUN apt-get update
RUN apt-get install -y qemu

COPY output/images/bzImage /
COPY output/images/rootfs.qcow /rootfs.qcow

ENTRYPOINT [ "qemu-system-x86_64", "-M", "pc-i440fx-2.8", "-enable-kvm", "-m", "2048", "-kernel", "bzImage", "-drive", "file=rootfs.qcow,if=virtio,format=qcow2", "-append", "rootwait root=/dev/vda", "-net", "nic,model=virtio", "-net", "user,hostfwd=tcp::8080-:8080", "-loadvm", "petclinic", "-nographic" ]
```

> NOTE: the snapshot will only work in a container if it was made with a compatible machine type (`qemu-system-x86_64 -M help` for a list). The base image in the `Dockerfile` is Ubuntu 18.04 so the "bionic" machine types work, but those aren't present on non-Ubuntu hosts. The example here `pc-i440fx-2.8` is a lowest common denominator between all the systems I used including the `buildroot` container.

So

```
$ docker build -t localhost:5000/dsyer/snapshot .
$ docker push localhost:5000/dsyer/snapshot
```

and then you can run it

```
$ docker run --privileged -p 8080:8080 localhost:5000/dsyer/snapshot
```

and it will start almost as fast as the VM running on the host did. Actually it doesn't start as fast, and it's hard to understand the difference. The first start with docker takes nearly 2 seconds. But subsequently we can run with `docker start` and that takes less than a second. You can measure it with the `ttfr.sh` script:

```
$ ./ttfr.sh -d petclinic localhost:5000/dsyer/snapshot
...
</html>
Total of .906540588 seconds elapsed for process
```

It's still not super fast, it has to be said, and it relies on being able to `docker start` an existing container. Why is it not as fast as re-hydrating the VM image (running the same command) on the host?

> NOTE: Instead of `--privileged` you can use `--device=/dev/kvm:/dev/kvm`, but that's probably just as bad securitywise.

## Running on MySQL

You can use `docker-compose` to run MySQL on the host in a container (there's a `docker-compose.yml` in the Pet Clinic source). Then add `--spring.profiles.active=mysql` and `--spring.datasource.url=jdbc:mysql://172.17.0.1/petclinic` to the script that runs the app (checking the IP address of your Docker network). The app runs fine, of course, but you can also checkpoint it and run the snapshot. The result is that all the open connections get closed and the connection pool moans when it has to restart them all. After a snapshot launch:

```
# cat /var/log/petclinic
...
2020-05-14 07:42:57.703  WARN 178 --- [nio-8080-exec-4] com.zaxxer.hikari.pool.PoolBase          : HikariPool-1 - Failed to validate connection com.mysql.cj.jdbc.ConnectionImpl@2f9dac3f (No operations allowed after connection closed.). Possibly consider using a shorter maxLifetime value.
2020-05-14 07:42:57.705  WARN 178 --- [nio-8080-exec-4] com.zaxxer.hikari.pool.PoolBase          : HikariPool-1 - Failed to validate connection com.mysql.cj.jdbc.ConnectionImpl@6545665b (No operations allowed after connection closed.). Possibly consider using a shorter maxLifetime value.
...
```

but the app is running fine:

```
# curl localhost:8080/actuator/health
{"status": "UP"}
```

To make this more reliable you would need help stabilizing the hostname. DNS in Kubernetes should be fine for that, but the same snapshot will not run in Kubernetes and on the host. We have to compromise there somewhere, or else find a way to dynamically inject the hostname. Then you have to worry about other credentials that might not be known when the image is built. For this reason, it is probably a good idea eventually to have the snapshots managed in the cluster, not at build time. We could find ways to work around that in the application code, but it would be working against the grain of the developer tools (connection pools like to be immutable, for instance).