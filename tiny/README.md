A simple docker build for a container built from buildroot. With the JDK it ends up being about 190MB. Probably could be tweaked. Build the VM image and then run `docker build -t tiny -f tiny/Dockerfile .` in the parent directory. Then you can run it:

```
$ docker run -ti tiny -version
openjdk version "11.0.7" 2020-04-14
OpenJDK Runtime Environment (build 11.0.7+11)
OpenJDK 64-Bit Server VM (build 11.0.7+11, mixed mode)
```