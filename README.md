# k3s-multipass-cluster
- Kubernetes multi-nodes cluster with k3s and multipass
- The script is an automation of the medium story: https://medium.com/@mattiaperi/kubernetes-cluster-with-k3s-and-multipass-7532361affa3
- Working on MacOS and k3s v1.17.3+k3s1

## WARNING
- the script is just for personal use and it works for me. You are more then welcome to use it, but this comes with no warranty. Use it at your own risk.

## how to use it
`$ curl -sfL https://raw.githubusercontent.com/mattiaperi/k3s-multipass-cluster/master/k3s-multipass-cluster.bash | bash -`

Some flags are available:
```bash
$ ./k3s-multipass-cluster.bash -h
k3s-multipass-cluster.bash accepted CLI arguments are:
  [-h|--help]                       Prints this help
  [-v|--version <desired_version>]  When not defined it defaults to the latest tested version
                                    e.g. --version v1.17.3+k3s1 or -v latest
  [-d|--no-deploy <component>]      When not defined it installs all 3rd parts components
                                    e.g. --no-deploy dashboard
```

`$ ./k3s-multipass-cluster.bash --version v1.17.2+k3s1 --no-deploy dashboard --no-deploy weavescope --no-deploy prometheus`
