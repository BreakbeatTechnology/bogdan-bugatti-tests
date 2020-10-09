#!/bin/bash

# Environment variables used in this script:
# $voltype - Specifies the type of volume being used in this test
# $bucket - Specifies which S3 bucket will receive the test results

# Checking test's run time
export scriptstart=$(date +%s)

# Install fio & ioping
apt update
apt install awscli fio ioping nvme-cli -y

# Declare test dir var
export dir=/root/tests/$(date +"%y-%m-%d")

# Create dir to output tests
mkdir -p $dir/

# Enumerate GP2 and IO2 volumes attached to this instance with tag type:perftest
export gp2vols=$(aws ec2 describe-volumes --filters Name=volume-type,Values=gp2 Name=attachment.instance-id,Values=$(curl http://169.254.169.254/latest/meta-data/instance-id) Name=tag:type,Values=perftest --query "Volumes[*].{ID:VolumeId}" --region us-west-2 --output text)
export io2vols=$(aws ec2 describe-volumes --filters Name=volume-type,Values=io2 Name=attachment.instance-id,Values=$(curl http://169.254.169.254/latest/meta-data/instance-id) Name=tag:type,Values=perftest --query "Volumes[*].{ID:VolumeId}" --region us-west-2 --output text)
export ephvol=$(nvme list | grep NVMe | awk '{print $1}' | cut -c 6-)

# Determine volume IDs for each volumes
export volidb=$(echo $gp2vols | awk '{print $1}' | cut -c 5-) # Volume ID of /dev/sdb
export volidc=$(echo $gp2vols | awk '{print $2}' | cut -c 5-) # Volume ID of /dev/sdc
export volidd=$(echo $gp2vols | awk '{print $3}' | cut -c 5-) # Volume ID of /dev/sdd
export volidx=$(echo $io2vols | awk '{print $1}' | cut -c 5-) # Volume ID of /dev/sdx
export volidy=$(echo $io2vols | awk '{print $2}' | cut -c 5-) # Volume ID of /dev/sdy
export volidz=$(echo $io2vols | awk '{print $3}' | cut -c 5-) # Volume ID of /dev/sdz

# Determine NVMe volume number based on volume ID
export nvmeb=$(lsblk -o +SERIAL | grep $volidb | awk '{print $1}') # NVME volume ID of /dev/sdb
export nvmec=$(lsblk -o +SERIAL | grep $volidc | awk '{print $1}') # NVME volume ID of /dev/sdc
export nvmed=$(lsblk -o +SERIAL | grep $volidd | awk '{print $1}') # NVME volume ID of /dev/sdd
export nvmex=$(lsblk -o +SERIAL | grep $volidx | awk '{print $1}') # NVME volume ID of /dev/sdx
export nvmey=$(lsblk -o +SERIAL | grep $volidy | awk '{print $1}') # NVME volume ID of /dev/sdy
export nvmez=$(lsblk -o +SERIAL | grep $volidz | awk '{print $1}') # NVME volume ID of /dev/sdz

# Single volume tests
for i in $nvmeb $nvmex ; do \
	export singlestart=$(date +%s)

	# Create label, partition, and filesystem for single volume
	parted -s -a optimal -- /dev/"$i" mklabel gpt mkpart primary 1MiB -2048s && sleep 1 && mkfs.ext4 -F /dev/"$i"p1

	# Create mount dir and mount single volume
	mkdir /mnt/"$i"
	mount /dev/"$i"p1 /mnt/"$i"

	# Run tests 5 times on the volume to take average of results
	for j in {1..5}; do \
		ioping -c 30 /mnt/"$i" | tee $dir/ioping_single_"$i"_"$j"
		fio --randrepeat=1 --ioengine=libaio --direct=1 --gtod_reduce=1 --name=test --filename=/mnt/"$i"/random_read_write.fio --bs=4k --iodepth=64 --size=4G --readwrite=randrw --rwmixread=75 --output=$dir/fio_randrw4G_single_"$i"_"$j" 
	done
	export singleend=$(date +%s)
	
	# Note time taken for single volume prep & test in notes
	echo -e "Runtime for tests on $i : $(( $singleend - $singlestart )) " >> $dir/notes
done

# Create the RAID devices
	# GP2 RAID device
		mdadm --create --verbose /dev/md/gp2 --level=0 --raid-devices=2 /dev/$nvmec /dev/$nvmed

	# IO2 RAID device
		mdadm --create --verbose /dev/md/io2 --level=0 --raid-devices=2 /dev/$nvmey /dev/$nvmez

# RAID volume tests
for i in gp2 io2; do \
	export raidstart=$(date +%s)

	# No need to create label and partition, just filesystem
	mkfs.ext4 -F /dev/md/"$i"

	# Create dir and mount RAID volume
	mkdir -p /mnt/md/"$i"
	mount /dev/md/"$i" /mnt/md/"$i"

	# Run tests 5 times on the volume to take average of results
	for j in {1..5}; do \
			ioping -c 30 /mnt/md/"$i" | tee $dir/ioping_raid_"$i"_"$j"
			fio --randrepeat=1 --ioengine=libaio --direct=1 --gtod_reduce=1 --name=test --filename=/mnt/md/"$i"/random_read_write.fio --bs=4k --iodepth=64 --size=4G --readwrite=randrw --rwmixread=75 --output=$dir/fio_randrw4G_raid_"$i"_"$j"
	done
	export raidend=$(date +%s)

	# Note time taken for RAID volume prep & test in notes
	echo -e "Runtime for tests on $i : $(( $raidend - $raidstart ))" >> $dir/notes
done

# Ephemeral storage tests
export ephstart=$(date +%s)

# Create label, partition, and filesystem for ephemeral storage volume
parted -s -a optimal -- /dev/"$ephvol" mklabel gpt mkpart primary 1MiB -2048s && sleep 1 && mkfs.ext4 -F /dev/"$ephvol"p1

# Create mount dir and mount ephemeral storage volume
mkdir -p /mnt/$ephvol
mount /dev/"$ephvol"p1 /mnt/$ephvol

# Run tests 5 times on the volume to take average of results
for i in {1..5}; do \
	ioping -c 30 /mnt/$ephvol | tee $dir/ioping_eph_"$i"
	fio --randrepeat=1 --ioengine=libaio --direct=1 --gtod_reduce=1 --name=test --filename=/mnt/$ephvol/random_read_write.fio --bs=4k --iodepth=64 --size=4G --readwrite=randrw --rwmixread=75 --output=$dir/fio_randrw4G_eph_"$j"
done
export ephend=$(date +%s)

# Note time taken for ephemeral storage volume prep & test in notes
echo -e "Runtime for tests on eph: $(( $ephend - $ephstart )) "

# Get Instance ID to use in s3 path for results
export instanceid=$(curl http://169.254.169.254/latest/meta-data/instance-id)

export scriptend=$(date +%s)

# Note total time taken for script in notes
echo -e "Total runtime: $(( $scriptend - $scriptstart )) seconds" >> $dir/notes

# Note which /dev/nvme device maps to which volume ID in notes
echo -e $nvmeb = $volidb"\n"$nvmec = $volidc"\n"$nvmed = $volidd"\n"$nvmex = $volidx"\n"$nvmey = $volidy"\n"$nvmez = $volidz >> $dir/notes

# Upload test results to S3
aws s3 sync /root/tests/ s3://$bucket/tests/$instanceid/
