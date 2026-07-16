Solve this question on: `kubectl config use-context kind-cka`

Several workloads run in namespace `monitor`. One of them is consuming an
unusual amount of CPU.

1. Using `kubectl top`, identify the Pod with the **highest CPU usage**
   in namespace `monitor`.
2. Write the name of that Pod (just the Pod name, one line) to the file
   `~/cka/ts-08/top-pod.txt`.

Note: metrics may take a minute after Pod start to appear.
