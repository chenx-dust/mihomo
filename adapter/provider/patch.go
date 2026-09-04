package provider

import "sync/atomic"

var healthCheckSuspended atomic.Bool

func SuspendHealthCheck(suspended bool) {
	healthCheckSuspended.Store(suspended)
}

func (pp *proxySetProvider) GetSubscriptionInfo() *SubscriptionInfo {
	return pp.subscriptionInfo
}
