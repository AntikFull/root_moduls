//go:build !linux

// РРРРССРР РРС СРРСРРё РР РРСРёРР СРРСРРРССРёРР (Windows/macOS): СРССРС СРР
// РСС СРРРР РР РРРССРРРССС, РР РРССРСС Рё СРСРРСР РСРРС РРРРР РСРРРСССС РРРРРСРР.

package main

import (
	"errors"
	"net"
)

func originalDst(c *net.TCPConn) (*net.TCPAddr, error) {
	return nil, errors.New("SO_ORIGINAL_DST is only available on Linux/Android")
}
