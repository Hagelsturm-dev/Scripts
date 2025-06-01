//go:build !windows

package main

import (
    "fmt"
    "os"
    "golang.org/x/sys/unix"
    "unsafe"
)

type unixTun struct {
    file *os.File
}

func (t *unixTun) ReadPacket() ([]byte, error) {
    buf := make([]byte, 1500)
    n, err := t.file.Read(buf)
    return buf[:n], err
}

func (t *unixTun) WritePacket(data []byte) error {
    _, err := t.file.Write(data)
    return err
}

func (t *unixTun) Close() error {
    return t.file.Close()
}

func createTun(localIP string) (TunDevice, error) {
    f, err := os.OpenFile("/dev/net/tun", os.O_RDWR, 0)
    if err != nil {
        return nil, err
    }

    var ifr [unix.IFNAMSIZ + 64]byte
    copy(ifr[:], []byte("tun0\x00"))
    *(*uint16)(unsafe.Pointer(&ifr[unix.IFNAMSIZ])) = unix.IFF_TUN | unix.IFF_NO_PI

    _, _, errno := unix.Syscall(unix.SYS_IOCTL, f.Fd(), uintptr(unix.TUNSETIFF), uintptr(unsafe.Pointer(&ifr[0])))
    if errno != 0 {
        return nil, fmt.Errorf("TUN ioctl failed: %v", errno)
    }

    fmt.Printf("✅ TUN /dev/net/tun aktiv. Bitte IP setzen:
sudo ip addr add %s dev tun0
", localIP)

    return &unixTun{file: f}, nil
}
