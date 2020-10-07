#!/bin/bash

# Environment variables used in this script:
# $voltype - Specifies the type of volume being used in this test
# $bucket - Specifies which S3 bucket will receive the test results

# Install fio & ioping
apt update
apt install awscli fio ioping -y

# Declare date var
export dir=/root/tests/$(date +"%y-%m-%d");


#Create dir to output tests
mkdir -p $dir/

# If volume type is gp2 or io2 don't bother with /dev/nvme*
if [ "$voltype" == "gp2" ] || [ "$voltype" == "io2" ]; then
	# Label, partition, and create fs on EBS volume, then mount them to 
	# respective dirs in /mnt/
	parted -s -a optimal -- /dev/xvdb \
	mklabel gpt \
	mkpart primary 1MiB -2048s
	mkfs.ext4 /dev/xvdb1
	mkdir /mnt/xvdb1
	mount /dev/xvdb1 /mnt/xvdb1
	ioping -c 30 /mnt/xvdb1/ | tee $dir/ioping
	sudo fio --randrepeat=1 --ioengine=libaio --direct=1 --gtod_reduce=1 --name=test --filename=/mnt/xvdb1/random_read_write.fio --bs=4k --iodepth=64 --size=1G --readwrite=randrw --rwmixread=75 --output=$dir/fio_randrw1G_ebs

# Else if volume type is instance store do the things with /dev/nvme1n1p1
elif [ "$voltype" == "eph" ]; then
	# If we added an instance store volume to the instance, label/partition/mount 
	# and run the tests 
	sudo parted -s -a optimal -- /dev/nvme1n1 mklabel gpt mkpart primary 1MiB -2048s; 
    sudo mkfs.ext4 /dev/nvme1n1p1
    sudo mkdir /mnt/nvme1n1p1
    sudo mount /dev/nvme1n1p1 /mnt/nvme1n1p1
    ioping -c 30 /mnt/nvme1n1p1/ | tee $dir/ioping_ephemeral
    sudo fio --randrepeat=1 --ioengine=libaio --direct=1 --gtod_reduce=1 --name=test --filename=/mnt/nvme1n1p1/random_read_write.fio --bs=4k --iodepth=64 --size=1G --readwrite=randrw --rwmixread=75 --output=$dir/fio_randrw1G_ephemeral
fi

aws s3 sync /root/tests/ s3://$bucket/tests/$voltype/
