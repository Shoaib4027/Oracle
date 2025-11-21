ls miib_arch_* | \
awk -F'[_ .]' '
{
    thread=$3;
    seq=$4;
    list[thread][seq]=1;
}

END {
    for (t in list) {
        n = asorti(list[t], seqs);
        prev = seqs[1];

        printf("Thread %s: ", t);

        sep = "";

        for (i=2; i<=n; i++) {
            curr = seqs[i];

            if (curr > prev + 1) {
                start = prev + 1;
                end   = curr - 1;
                count = end - start + 1;

                printf("%sMissing %d-%d (%d)", sep, start, end, count);
                sep=", ";
            }

            prev = curr;
        }

        print "";
    }
}'

-- rfs (PID:260512): Archived Log entry 413517 added for B-1167322138.T-2.S-138253 LOS:0x0000028e982bda5a NXS:0x0000028e983722e5 NAB:17595470 ID 0x2db88d97 LAD:1
