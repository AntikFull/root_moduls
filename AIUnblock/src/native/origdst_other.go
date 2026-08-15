//go:build !linux

// Заглушка для сборки на других операционных системах (Windows/macOS):
// функционал SO_ORIGINAL_DST доступен только на Linux/Android.

package main

import (
	"errors"
	"net"
)

func originalDst(c *net.TCPConn) (*net.TCPAddr, error) {
	return nil, errors.New("SO_ORIGINAL_DST is only available on Linux/Android")
}
