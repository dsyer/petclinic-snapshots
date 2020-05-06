
How to run the [Spring Petclinic](https://github.com/spring-projects/spring-petclinic) on Kubernetes with subsecond scale up. The first step is to build a lightweight VM image with [Buildroot](https://github.com/buildroot/buildroot). Then you log in and get the Petclinic running. Then you containerize it, and finally deploy to Kubernetes. 

TL;DR You can containerize a VM snapshot. It's fast, but not as fast as if you run it on the host. You can start Petclinic in less than half a second on the host, and less than a second in a container. In Kubernetes it feels pretty much instantaneous. The containers have to run `--privileged`.

## Get Buildroot

```
$ mkdir -p buildroot
$ cd buildroot
$ curl -L https://github.com/buildroot/buildroot/tarball/master | tar -zxf - --strip-components=1
```

## Build a VM Image

```
$ make qemu_x86_64_defconfig
$ make menuconfig
```

Configuration options:

* "Toolchain": select `glibc` and `C++` support
* "Target Packages": select `X.Org` from "Graphic libraries..." and `openjdk` from "Interpreter languages..." and "openssh" from "Networking..."
* "Filesystem images": select a larger filesystem images size in and make it an `ext4` filesystem type
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
$ qemu-system-x86_64 -M pc-i440fx-2.11 -enable-kvm -m 2048 -kernel bzImage -drive file=rootfs.qcow,if=virtio,format=qcow2 -append 'rootwait root=/dev/vda' -net nic,model=virtio -net user,hostfwd=tcp::2222-:22,hostfwd=tcp::8080-:8080
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

## Run the Petclinic

So now we need to copy in a JAR file that we can run (that's where a root password comes in handy).

```
$ scp spring-petclinic-2.3.0.BUILD-SNAPSHOT.jar -P 2222 root@192.168.2.19:~/petclinic.jar
root@192.168.2.19's password: 
spring-petclinic-2.3.0.BUILD-SNAPSHOT.jar        100%   46MB  93.6MB/s   00:00    
```

And we can run it in the VM:

```
# java -jar petclinic.jar 


              |\      _,,,--,,_
             /,`.-'`'   ._  \-;;,_
  _______ __|,4-  ) )_   .;.(__`'-'__     ___ __    _ ___ _______
 |       | '---''(_/._)-'(_\_)   |   |   |   |  |  | |   |       |
 |    _  |    ___|_     _|       |   |   |   |   |_| |   |       | __ _ _
 |   |_| |   |___  |   | |       |   |   |   |       |   |       | \ \ \ \
 |    ___|    ___| |   | |      _|   |___|   |  _    |   |      _|  \ \ \ \
 |   |   |   |___  |   | |     |_|       |   | | |   |   |     |_    ) ) ) )
 |___|   |_______| |___| |_______|_______|___|_|  |__|___|_______|  / / / /
 ==================================================================/_/_/_/

:: Built with Spring Boot :: 2.3.0.M4


2020-05-01 14:46:30.675  INFO 158 --- [           main] o.s.s.petclinic.PetClinicApplication     : Starting PetClinicApplication v2.3.0.BUILD-SNAPSHOT on buildroot with PID 158 (/root/petclinic.jar started by root in /root)
...
2020-05-01 14:46:45.137  INFO 158 --- [           main] o.s.b.w.embedded.tomcat.TomcatWebServer  : Tomcat started on port(s): 8080 (http) with context path ''
2020-05-01 14:46:45.143  INFO 158 --- [           main] o.s.s.petclinic.PetClinicApplication     : Started PetClinicApplication in 15.224 seconds (JVM running for 16.152)
```

So it took 15 seconds to start, but we constrained the system a lot, so it's not expected to be super quick. If we gave it more memory and cpus it would start much quicker, probably closer to 3 seconds on the host. Warm it up by curling it from the host:

```
$ curl 192.168.2.19:8080
...
</html>
```

## Take a Snapshot

We can take a snapshot:

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

## Containerize the Snapshot

When you have the snaphot you can build it into a container image. Here's a `Dockerfile`:

```
FROM cloudfoundry/run:base

RUN apt-get update
RUN apt-get install -y qemu

COPY output/images/bzImage /
COPY output/images/rootfs.qcow /rootfs.qcow

ENTRYPOINT [ "qemu-system-x86_64", "-M", "pc-i440fx-2.11", "-enable-kvm", "-m", "2048", "-kernel", "bzImage", "-drive", "file=rootfs.qcow,if=virtio,format=qcow2", "-append", "rootwait root=/dev/vda", "-net", "nic,model=virtio", "-net", "user,hostfwd=tcp::8080-:8080", "-loadvm", "petclinic", "-nographic" ]
```

> NOTE: the snapshot will only work in a container if it was made with a compatible machine type (`qemu-system-x86_64 -M help` for a list). The base image in the `Dockerfile` is Ubuntu 18.04 so the "bionic" machine types work, but those aren't present on non-Ubuntu hosts.

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