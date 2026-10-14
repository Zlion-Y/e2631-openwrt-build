set -x
mkdir -p /tmp/wifi-caldata
mount -t jffs2 /dev/mtdblock2 /tmp/wifi-caldata 2>&1 || mount -t jffs2 /dev/mtd2 /tmp/wifi-caldata
ls -l /tmp/wifi-caldata
hexdump -v -n 32 -e '16/1 "%02x " "\n"' /tmp/wifi-caldata/caldata
mkdir -p /lib/firmware/mediatek
cp /tmp/wifi-caldata/caldata /lib/firmware/mediatek/mt7916_eeprom.bin
ls -l /lib/firmware/mediatek/mt7916_eeprom.bin
umount /tmp/wifi-caldata
echo "=== drivers present ==="
ls /sys/bus/pci/drivers/
ls /sys/bus/pci/devices/0000:01:00.0/driver 2>&1
echo "=== rebind ==="
echo 0000:01:00.0 > /sys/bus/pci/drivers/mt7915e/bind 2>&1
sleep 6
dmesg | tail -25
echo "=== phys ==="
ls /sys/class/ieee80211/ 2>&1
iw dev 2>&1
