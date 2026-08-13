//go:build linux

// РСРРСРРСРРСРСР pass-through СССРССРСРС СРРСРР РР Linux/Android.
// РСРРСРРР РёР main.go, ССРРС РССРРСРРР РРР (РРССРСС, РСРРС, DoH) СРРРёСРРСС
// Рё РСРРРССРСС РР РСРРР РРСРёРР СРРСРРРССРёРР, РРРССРС Windows.

package main

import (
	"errors"
	"net"
	"syscall"
	"unsafe"
)

const soOriginalDst = 80

func originalDst(c *net.TCPConn) (*net.TCPAddr, error) {
	// Use Go's per-OS/per-architecture getsockopt wrapper instead of hard-coded
	// Linux syscall numbers. IPv6Mreq is simply a >=16-byte buffer here; the
	// kernel writes a sockaddr_in for SO_ORIGINAL_DST into the supplied memory.
	// This is the same getsockopt ABI the Android/Linux kernel expects.
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
