ls miib_arch_* | \
awk -F'[_ .]' '
{
    thread=$3;
    seq=$4;
    list[thread][seq]=1;
}

END {
    for (t in list) {
        print "Thread:", t;

        # gather sorted sequence numbers
        n = asorti(list[t], seqs);

        prev = seqs[1];

        for (i=2; i<=n; i++) {
            curr = seqs[i];

            if (curr > prev + 1) {
                for (m = prev+1; m < curr; m++) {
                    print "  Missing:", m;
                }
            }
            prev = curr;
        }
    }
}'