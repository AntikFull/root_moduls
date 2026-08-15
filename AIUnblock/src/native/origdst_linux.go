//go:build linux

// Безопасный pass-through поддерживается только на Linux/Android.
// Вынесено из main.go, чтобы остальные инструменты (роутер, пробы, DoH) собирались
// и запускались на любой платформе разработки, включая Windows.

package main

import (
	"errors"
	"net"
	"syscall"
	"unsafe"
)

const soOriginalDst = 80

func originalDst(c *net.TCPConn) (*net.TCPAddr, error) {
	// Использование getsockopt wrapper для определения оригинального назначения
	rc, err := c.SyscallConn()
	if err != nil {
		return nil, err
	}
	var out *net.TCPAddr
	var inner error
	err = rc.Control(func(fd uintptr) {
		mreq, e := syscall.GetsockoptIPv6Mreq(int(fd), syscall.SOL_IP, soOriginalDst)
		if e != nil {
			inner = e
			return
		}
		raw := (*[syscall.SizeofIPv6Mreq]byte)(unsafe.Pointer(mreq))[:]
		out, inner = decodeOriginalDst(raw)
	})
	if err != nil {
		return nil, err
	}
	if inner != nil {
		return nil, inner
	}
	if out == nil {
		return nil, errors.New("SO_ORIGINAL_DST unavailable")
	}
	return out, nil
}
