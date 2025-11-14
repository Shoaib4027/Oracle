#!/bin/bash

ls miib_arch_* | \
awk -F'[_ .]' '
{
    thread=$3; 
    seq=$4;
    key=thread;
    arr[key][seq]=1;

    if (seq > max[key]) max[key]=seq;
    if (min[key] == "" || seq < min[key]) min[key]=seq;
}

END {
    for (t in arr) {
        printf "Thread %s:\n", t;
        for (i=min[t]; i<=max[t]; i++) {
            if (!(i in arr[t])) {
                printf "  Missing sequence: %d\n", i;
            }
        }
    }
}'