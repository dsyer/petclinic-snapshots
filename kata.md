Kata lets you run containers in VMs. People like it because it has better isolation than runc.

Check if it is going to work:

```
$ docker run --privileged -it katadocker/kata-deploy sh -c 'ln -s /opt/kata-artifacts/opt/kata/ /opt/ && /opt/kata-artifacts/opt/kata/bin/kata-runtime kata-check'
System is capable of running Kata Containers
System can currently create Kata Containers
```

The [quick start guide](https://github.com/kata-containers/packaging/blob/master/kata-deploy/README.md) worked for docker:

```
$ docker run -v /opt/kata:/opt/kata -v /var/run/dbus:/var/run/dbus -v /run/systemd:/run/systemd -v /etc/docker:/etc/docker -it katadocker/kata-deploy kata-deploy-docker install
$ docker run --runtime=kata-qemu -it busybox
/ # ls
bin   dev   etc   home  proc  root  sys   tmp   usr   var
```

Sometimes running a bigger (JVM) container fails like this though:

```
$ docker run -p 8080:8080 --runtime=kata-qemu dsyer/petclinic
library initialization failed - unable to allocate file descriptor table - out of memory
```

and I found you could fix that by passing an explicit ulimit on the docker command line:

```
$ docker run -p 8080:8080 --ulimit nofile=122880:122880 --runtime=kata-qemu dsyer/petclinic
```

When that container is running you see a `qemu` process on the host with a long command line.


But you can't run a container that itself runs qemu:

```
$ docker run --privileged -p 8080:8080 --runtime=kata-qemu localhost:5000/dsyer/snapshot
docker: Error response from daemon: OCI runtime create failed: QMP command failed: Failed to connect socket /dev/nvme0: Connection refused: unknown.
ERRO[0001] error waiting for container: context canceled
```

> NOTE: `/dev/nvme0` is the device that maps to my hard disk controller on the host. I have no idea why it showed up in the error message as it isn't referenced in the container entry point or in the Kata-generated qemu command line.

With Kubernetes things were more complicated. I had issues getting the `katadocker/kata-deploy` container running. It seemed to always crap out and the `DeamonSet` never became ready. The errors looked like authentication errors, but it's possible it was just screwing up `containerd` and falling into a hole. I logged into the Kind node using `docker exec` and messed about with `ctrctl` and `ctr` to pull and verify that the image was available, at which point the Pod was happier.

Kata [does not support cri v2](https://github.com/kata-containers/packaging/issues/881). I was able to get it working by manually patching the config file and restarting containerd:

```
$ sed -i -e 's/plugins.cri/plugins."io.containerd.grpc.v1.cri"/' /etc/containerd/config.toml
$ systemctl restart containerd
```

but obviously that is a bit crap, and I'm not sure if I had to do that before or after the `kata-deploy` Pod got itself into a ready state.

Once that was working I could run a regular container, but not the qemu snapshot one, consistent with what happened with Docker.