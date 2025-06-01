//go:build windows

package main

import (
    "fmt"
    "golang.zx2c4.com/wintun"
)

type winTunWrapper struct {
    adapter *wintun.Adapter
    session wintun.Session
}

func (w *winTunWrapper) ReadPacket() ([]byte, error) {
    pkt, err := w.session.ReceivePacket()
    if err != nil {
        return nil, err
    }
    data := make([]byte, len(pkt))
    copy(data, pkt)
    w.session.ReleaseReceivePacket(pkt)
    return data, nil
}

func (w *winTunWrapper) WritePacket(data []byte) error {
    pkt, err := w.session.AllocateSendPacket(len(data))
    if err != nil {
        return err
    }
    copy(pkt, data)
    return w.session.SendPacket(pkt)
}

func (w *winTunWrapper) Close() error {
    w.session.End()
    return w.adapter.Close()
}

func createTun(localIP string) (TunDevice, error) {
    adapter, err := wintun.CreateAdapter("GoTun", "Wintun", nil)
    if err != nil {
        return nil, err
    }
    session, err := adapter.StartSession(0x10000)
    if err != nil {
        return nil, err
    }

    fmt.Println("✅ WinTun aktiv.")
    fmt.Printf("⚠️ Bitte manuell IP setzen:
netsh interface ip set address name="GoTun" static %s
", localIP)

    return &winTunWrapper{adapter: adapter, session: session}, nil
}
