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


oracle@eisprgtw02 gg_foreign_archives]$ ls -ltrh miib_arch_4* | sort -k9  |  tail -n100
-rw-r----- 1 oracle oinstall  8.2G Nov 14 12:55 miib_arch_4_126493_1156944397.log
-rw-r----- 1 oracle oinstall  8.2G Nov 14 12:57 miib_arch_4_126494_1156944397.log
-rw-r----- 1 oracle oinstall  8.3G Nov 14 13:00 miib_arch_4_126495_1156944397.log
-rw-r----- 1 oracle oinstall  8.2G Nov 14 13:02 miib_arch_4_126496_1156944397.log
-rw-r----- 1 oracle oinstall  8.3G Nov 14 13:05 miib_arch_4_126497_1156944397.log
-rw-r----- 1 oracle oinstall  8.3G Nov 14 13:08 miib_arch_4_126498_1156944397.log
-rw-r----- 1 oracle oinstall  8.3G Nov 14 13:10 miib_arch_4_126499_1156944397.log
-rw-r----- 1 oracle oinstall  8.2G Nov 14 13:13 miib_arch_4_126500_1156944397.log
-rw-r----- 1 oracle oinstall  8.2G Nov 14 13:16 miib_arch_4_126501_1156944397.log
-rw-r----- 1 oracle oinstall  7.8G Nov 14 13:19 miib_arch_4_126502_1156944397.log
-rw-r----- 1 oracle oinstall  8.2G Nov 14 13:22 miib_arch_4_126503_1156944397.log
-rw-r----- 1 oracle oinstall  8.2G Nov 14 13:25 miib_arch_4_126504_1156944397.log
-rw-r----- 1 oracle oinstall  8.3G Nov 14 13:27 miib_arch_4_126505_1156944397.log
-rw-r----- 1 oracle oinstall  8.2G Nov 14 13:30 miib_arch_4_126506_1156944397.log
-rw-r----- 1 oracle oinstall  8.2G Nov 14 13:33 miib_arch_4_126507_1156944397.log
-rw-r----- 1 oracle oinstall  8.2G Nov 14 13:36 miib_arch_4_126508_1156944397.log
-rw-r----- 1 oracle oinstall  8.3G Nov 14 13:38 miib_arch_4_126509_1156944397.log
-rw-r----- 1 oracle oinstall  8.2G Nov 14 13:41 miib_arch_4_126510_1156944397.log
-rw-r----- 1 oracle oinstall  8.2G Nov 14 13:44 miib_arch_4_126511_1156944397.log
-rw-r----- 1 oracle oinstall  8.2G Nov 14 13:47 miib_arch_4_126512_1156944397.log
-rw-r----- 1 oracle oinstall  8.2G Nov 14 13:50 miib_arch_4_126513_1156944397.log
-rw-r----- 1 oracle oinstall  8.2G Nov 14 13:53 miib_arch_4_126514_1156944397.log
-rw-r----- 1 oracle oinstall  8.2G Nov 14 13:56 miib_arch_4_126515_1156944397.log
-rw-r----- 1 oracle oinstall  6.0G Nov 14 13:58 miib_arch_4_126516_1156944397.log
-rw-r----- 1 oracle oinstall  8.2G Nov 14 14:01 miib_arch_4_126517_1156944397.log
-rw-r----- 1 oracle oinstall  8.2G Nov 14 14:04 miib_arch_4_126518_1156944397.log
-rw-r----- 1 oracle oinstall  8.2G Nov 14 14:07 miib_arch_4_126519_1156944397.log
-rw-r----- 1 oracle oinstall  8.2G Nov 14 14:11 miib_arch_4_126520_1156944397.log
-rw-r----- 1 oracle oinstall  8.3G Nov 14 14:13 miib_arch_4_126521_1156944397.log
-rw-r----- 1 oracle oinstall  8.3G Nov 14 14:17 miib_arch_4_126522_1156944397.log
-rw-r----- 1 oracle oinstall  8.2G Nov 14 14:20 miib_arch_4_126523_1156944397.log
-rw-r----- 1 oracle oinstall  8.3G Nov 14 14:23 miib_arch_4_126524_1156944397.log
-rw-r----- 1 oracle oinstall  8.2G Nov 14 14:26 miib_arch_4_126525_1156944397.log
-rw-r----- 1 oracle oinstall  8.3G Nov 14 14:29 miib_arch_4_126526_1156944397.log
-rw-r----- 1 oracle oinstall  8.2G Nov 14 14:32 miib_arch_4_126527_1156944397.log
-rw-r----- 1 oracle oinstall  8.2G Nov 14 14:35 miib_arch_4_126528_1156944397.log
-rw-r----- 1 oracle oinstall  8.2G Nov 14 14:38 miib_arch_4_126529_1156944397.log
-rw-r----- 1 oracle oinstall  8.3G Nov 14 14:41 miib_arch_4_126530_1156944397.log
-rw-r----- 1 oracle oinstall  4.2G Nov 14 14:43 miib_arch_4_126531_1156944397.log
-rw-r----- 1 oracle oinstall  8.2G Nov 14 14:46 miib_arch_4_126532_1156944397.log
-rw-r----- 1 oracle oinstall  3.8G Nov 14 14:47 miib_arch_4_126533_1156944397.log
-rw-r----- 1 oracle oinstall  8.3G Nov 14 14:50 miib_arch_4_126534_1156944397.log
-rw-r----- 1 oracle oinstall  8.2G Nov 14 14:53 miib_arch_4_126535_1156944397.log
-rw-r----- 1 oracle oinstall  8.3G Nov 14 14:56 miib_arch_4_126536_1156944397.log
-rw-r----- 1 oracle oinstall  8.2G Nov 14 14:59 miib_arch_4_126537_1156944397.log
-rw-r----- 1 oracle oinstall  8.2G Nov 14 15:02 miib_arch_4_126538_1156944397.log
-rw-r----- 1 oracle oinstall  8.3G Nov 14 15:05 miib_arch_4_126539_1156944397.log
-rw-r----- 1 oracle oinstall  8.2G Nov 14 15:07 miib_arch_4_126540_1156944397.log
-rw-r----- 1 oracle oinstall  8.3G Nov 14 15:10 miib_arch_4_126541_1156944397.log
-rw-r----- 1 oracle oinstall  8.2G Nov 14 15:13 miib_arch_4_126542_1156944397.log
-rw-r----- 1 oracle oinstall  8.2G Nov 14 15:16 miib_arch_4_126543_1156944397.log
-rw-r----- 1 oracle oinstall  8.2G Nov 14 15:18 miib_arch_4_126544_1156944397.log
-rw-r----- 1 oracle oinstall  8.2G Nov 14 15:21 miib_arch_4_126545_1156944397.log
-rw-r----- 1 oracle oinstall  8.2G Nov 14 15:24 miib_arch_4_126546_1156944397.log
-rw-r----- 1 oracle oinstall  8.2G Nov 14 15:27 miib_arch_4_126547_1156944397.log
-rw-r----- 1 oracle oinstall  1.4G Nov 14 15:27 miib_arch_4_126548_1156944397.log
-rw-r----- 1 oracle oinstall  8.4G Nov 14 15:30 miib_arch_4_126549_1156944397.log
-rw-r----- 1 oracle oinstall  8.4G Nov 14 15:33 miib_arch_4_126550_1156944397.log
-rw-r----- 1 oracle oinstall  8.3G Nov 14 15:36 miib_arch_4_126551_1156944397.log
-rw-r----- 1 oracle oinstall  8.2G Nov 14 15:39 miib_arch_4_126552_1156944397.log
-rw-r----- 1 oracle oinstall  8.2G Nov 14 15:41 miib_arch_4_126553_1156944397.log
-rw-r----- 1 oracle oinstall  8.2G Nov 14 15:44 miib_arch_4_126554_1156944397.log
-rw-r----- 1 oracle oinstall  8.2G Nov 14 15:47 miib_arch_4_126555_1156944397.log
-rw-r----- 1 oracle oinstall  8.2G Nov 14 15:50 miib_arch_4_126556_1156944397.log
-rw-r----- 1 oracle oinstall  8.3G Nov 14 15:53 miib_arch_4_126557_1156944397.log
-rw-r----- 1 oracle oinstall  6.3G Nov 14 15:55 miib_arch_4_126558_1156944397.log
-rw-r----- 1 oracle oinstall  8.4G Nov 14 15:58 miib_arch_4_126559_1156944397.log
-rw-r----- 1 oracle oinstall  4.2G Nov 14 15:59 miib_arch_4_126560_1156944397.log
-rw-r----- 1 oracle oinstall  8.2G Nov 14 16:02 miib_arch_4_126561_1156944397.log
-rw-r----- 1 oracle oinstall  8.2G Nov 14 16:05 miib_arch_4_126562_1156944397.log
-rw-r----- 1 oracle oinstall  8.2G Nov 14 16:08 miib_arch_4_126563_1156944397.log
-rw-r----- 1 oracle oinstall  8.2G Nov 14 16:11 miib_arch_4_126564_1156944397.log
-rw-r----- 1 oracle oinstall  8.2G Nov 14 16:14 miib_arch_4_126565_1156944397.log
-rw-r----- 1 oracle oinstall  8.2G Nov 14 16:17 miib_arch_4_126566_1156944397.log
-rw-r----- 1 oracle oinstall  8.3G Nov 14 16:20 miib_arch_4_126567_1156944397.log
-rw-r----- 1 oracle oinstall  8.3G Nov 14 16:23 miib_arch_4_126568_1156944397.log
-rw-r----- 1 oracle oinstall  8.2G Nov 14 16:26 miib_arch_4_126569_1156944397.log
-rw-r----- 1 oracle oinstall  8.2G Nov 14 16:29 miib_arch_4_126570_1156944397.log
-rw-r----- 1 oracle oinstall  4.3G Nov 14 16:30 miib_arch_4_126571_1156944397.log
-rw-r----- 1 oracle oinstall  8.3G Nov 14 16:34 miib_arch_4_126572_1156944397.log
-rw-r----- 1 oracle oinstall  4.0G Nov 14 16:35 miib_arch_4_126573_1156944397.log
-rw-r----- 1 oracle oinstall  8.3G Nov 14 16:38 miib_arch_4_126574_1156944397.log
-rw-r----- 1 oracle oinstall  8.2G Nov 14 16:41 miib_arch_4_126575_1156944397.log
-rw-r----- 1 oracle oinstall  8.3G Nov 14 16:45 miib_arch_4_126576_1156944397.log
-rw-r----- 1 oracle oinstall  8.2G Nov 14 16:48 miib_arch_4_126577_1156944397.log
-rw-r----- 1 oracle oinstall  8.2G Nov 14 16:51 miib_arch_4_126578_1156944397.log
-rw-r----- 1 oracle oinstall  8.2G Nov 14 16:55 miib_arch_4_126579_1156944397.log
-rw-r----- 1 oracle oinstall  8.2G Nov 14 16:58 miib_arch_4_126580_1156944397.log
-rw-r----- 1 oracle oinstall  7.5G Nov 14 17:01 miib_arch_4_126581_1156944397.log
-rw-r----- 1 oracle oinstall  8.2G Nov 14 17:04 miib_arch_4_126582_1156944397.log
-rw-r----- 1 oracle oinstall  8.3G Nov 14 17:08 miib_arch_4_126583_1156944397.log
-rw-r----- 1 oracle oinstall  8.2G Nov 14 17:11 miib_arch_4_126584_1156944397.log
-rw-r----- 1 oracle oinstall  8.2G Nov 14 17:15 miib_arch_4_126585_1156944397.log
-rw-r----- 1 oracle oinstall  8.2G Nov 14 17:19 miib_arch_4_126586_1156944397.log
-rw-r----- 1 oracle oinstall  8.3G Nov 14 17:22 miib_arch_4_126587_1156944397.log
-rw-r----- 1 oracle oinstall  8.3G Nov 14 17:26 miib_arch_4_126588_1156944397.log
-rw-r----- 1 oracle oinstall  8.2G Nov 14 17:32 miib_arch_4_126591_1156944397.log
-rw-r----- 1 oracle oinstall  8.2G Nov 14 17:36 miib_arch_4_126592_1156944397.log
-rw-r----- 1 oracle oinstall  8.2G Nov 14 17:40 miib_arch_4_126593_1156944397.log
-rw-r----- 1 oracle oinstall  2.8G Nov 14 17:41 miib_arch_4_126594_1156944397.log


so this is the list of thread4 but missing scripts is not showing missing range that is from 126588 to 126590
