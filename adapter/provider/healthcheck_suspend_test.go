package provider

import (
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"

	"github.com/metacubex/mihomo/adapter"
	"github.com/metacubex/mihomo/adapter/outbound"
	C "github.com/metacubex/mihomo/constant"
)

func TestSuspendHealthCheckSkipsChecksUntilResume(t *testing.T) {
	var requests atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		requests.Add(1)
		w.WriteHeader(http.StatusNoContent)
	}))
	defer server.Close()

	proxy := adapter.NewProxy(outbound.NewDirect())
	healthCheck := NewHealthCheck(
		[]C.Proxy{proxy},
		server.URL,
		1000,
		0,
		false,
		nil,
	)
	defer healthCheck.close()
	t.Cleanup(func() { SuspendHealthCheck(false) })

	SuspendHealthCheck(true)
	healthCheck.check()
	if got := requests.Load(); got != 0 {
		t.Fatalf("requests while suspended = %d, want 0", got)
	}

	SuspendHealthCheck(false)
	healthCheck.check()
	if got := requests.Load(); got != 1 {
		t.Fatalf("requests after resume = %d, want 1", got)
	}
}
