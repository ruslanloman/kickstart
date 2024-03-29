# kickstart recipe for creating openstack Centos 6 x86_64 images
# this is for a paravirt KVM machine, should work not only with Openstack, but also with Ovirt (and RHEV), virt-manager etc
# nux@li.nux.ro for comments, suggestions, problems

skipx
text
install

lang en_GB.UTF-8
keyboard uk
timezone --utc Europe/London

zerombr yes
clearpart --initlabel --all
bootloader --location=mbr --append=" biosdevname=0 console=ttyS0"

firewall --enabled
selinux --enforcing

part / --size=1024 --grow --fstype ext4 --asprimary

#for kvm images we'll try to randomise the root passwd anyway
authconfig --enableshadow --passalgo=sha512
rootpw putsomegoodpasswordhere

url --url=http://mirrors.coreix.net/centos/6/os/x86_64/
repo --name=Updates --baseurl=http://mirrors.coreix.net/centos/6/updates/x86_64/
repo --name=EPEL        --baseurl=http://mirrors.coreix.net/fedora-epel/6/x86_64/

repo --name=cloud-init --baseurl=http://repos.fedorapeople.org/repos/openstack/cloud-init/epel-6/

%packages --nobase
@core
openssh-server
cloud-init
ntp
wget
nano
acpid
sudo
%end

services --enabled=acpid,ntpd,sshd,cloud-init

# halt the machine once everything is done
shutdown

# post stuff, here's where we do all the customisation
%post

mkdir /root/.nux/

# some openstack implementations mess up the ssh dir selinux context when injecting the key, trying to work around it

cat << EOF > /root/.nux/.fixselinux
/bin/echo
/bin/echo "FIXING SELINUX ON /root/.ssh/"
/bin/sed -i s_/root/.nux/.fixselinux__g /etc/rc.d/rc.local
/bin/rm -rfv /root/.nux/
/sbin/restorecon -R -v /root/.ssh/
EOF

/bin/echo /root/.nux/.fixselinux >> /etc/rc.local
/bin/chmod +x /root/.nux/.fixselinux

# cloud-init is not able to expand the partition to match the new vdisk size, we need to work around it from the initramfs, before the filesystem gets mounted
# to accomplish this we need to generate a custom initrd
cat << EOF > 05-extend-rootpart.sh
#!/bin/sh

/bin/echo
/bin/echo RESIZING THE PARTITION

/bin/echo "d
n
p
1
2048

w
" | /sbin/fdisk -c -u /dev/vda 
/sbin/e2fsck -f /dev/vda1
/sbin/resize2fs /dev/vda1
EOF

chmod +x 05-extend-rootpart.sh

dracut --force --include 05-extend-rootpart.sh /mount --install 'echo fdisk e2fsck resize2fs' /boot/"initramfs-extend_rootpart-$(ls /boot/|grep initramfs|sed s/initramfs-//g)" $(ls /boot/|grep vmlinuz|sed s/vmlinuz-//g)
rm -f 05-extend-rootpart.sh

tail -4 /boot/grub/grub.conf | sed s/initramfs/initramfs-extend_rootpart/g| sed s/CentOS/ResizePartition/g | sed s/crashkernel=auto/crashkernel=0@0/g >> /boot/grub/grub.conf

# let's run the kernel & initramfs that expands the partition only once
echo "savedefault --default=1 --once" | grub --batch

# swap can lead to high I/O in a "cloud", but linux likes a bit of swap
# let's create a small swap file, 64 MB
fallocate -l 64M /swap.IMG
chmod 600 /swap.IMG
mkswap /swap.IMG
# and add it to fstab
cat << EOF >> /etc/fstab
/swap.IMG       swap    swap    defaults        0       0

EOF

cat << EOF >> /etc/cloud/cloud.cfg
growpart:
  mode: auto
  devices: ['/']
  ignore_growroot_disabled: false
EOF

cat << EOF > /etc/sudoers.d/cloud-user
cloud-user ALL=(root) NOPASSWD:ALL
EOF
# let's randomise the root password
head -n1 /dev/urandom | md5sum| awk {'print $1'} | passwd --stdin root

# no password ssh root login allowed
sed -i -e 's/^PasswordAuthentication yes.*/PasswordAuthentication no/g' /etc/ssh/sshd_config

# let's clean it up a bit
rm -rf /etc/ssh/*key*
rm -f /etc/udev/rules.d/*-persistent-*
sed -i '/HWADDR/d' /etc/sysconfig/network-scripts/ifcfg-eth0 
sed -i '/UUID/d' /etc/sysconfig/network-scripts/ifcfg-eth0 
sed -i 's,UUID=[^[:blank:]]*,/dev/vda1,' /etc/fstab
sed -i 's,UUID=[^[:blank:]]*,/dev/vda1,' /boot/grub/grub.conf
rm -f /root/anaconda-ks.cfg
rm -f /root/install.log
rm -f /root/install.log.syslog
find /var/log -type f -delete
