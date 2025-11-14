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
        start_gap = 0;

        for (i=2; i<=n; i++) {
            curr = seqs[i];

            if (curr > prev + 1) {
                if (start_gap == 0) start_gap = prev + 1;
                end_gap = curr - 1;

                printf("Thread %s: Missing %d-%d\n", t, start_gap, end_gap);
            }

            start_gap = 0;
            prev = curr;
        }
    }
}'