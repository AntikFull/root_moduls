//go:build !linux

// Заглушка для сборки на машине разработчика (Windows/macOS): роутер там
// всё равно не запускается, но парсеры и сетевые пробы можно проверять локально.

package main

import (
	"errors"
	"net"
)

func originalDst(c *net.TCPConn) (*net.TCPAddr, error) {
	return nil, errors.New("SO_ORIGINAL_DST is only available on Linux/Android")
}
